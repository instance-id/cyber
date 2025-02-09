const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const t = stdx.testing;
const cy = @import("cyber.zig");
const fmt = @import("fmt.zig");
const v = fmt.v;
const vm_ = @import("vm.zig");
const sema = cy.sema;
const gen = cy.codegen;
const cache = @import("cache.zig");
const core_mod = @import("builtins/core.zig");
const math_mod = @import("builtins/math.zig");
const os_mod = @import("builtins/os.zig");
const test_mod = @import("builtins/test.zig");

const log = stdx.log.scoped(.vm_compiler);

const f64NegOne = cy.Value.initF64(-1);
const f64One = cy.Value.initF64(1);

const dumpCompileErrorStackTrace = builtin.mode == .Debug and !cy.isWasm and true;

const Root = @This();

pub const VMcompiler = struct {
    alloc: std.mem.Allocator,
    vm: *cy.VM,
    buf: cy.ByteCodeBuffer,
    lastErr: []const u8,
    lastErrNode: cy.NodeId,
    lastErrChunk: CompileChunkId,

    /// Used to return additional info for an error.
    errorPayload: cy.NodeId,

    /// Sema model resulting from the sema pass.
    sema: sema.Model,

    /// Absolute specifier to additional loaders.
    moduleLoaders: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(cy.ModuleLoaderFunc)),

    /// Compilation units indexed by their id.
    chunks: std.ArrayListUnmanaged(CompileChunk),

    /// Imports are queued.
    importTasks: std.ArrayListUnmanaged(ImportTask),

    /// Stack for building func signatures. (eg. for nested func calls)
    typeStack: std.ArrayListUnmanaged(sema.Type),

    /// Buffer for building func signatures.
    tempTypes: std.ArrayListUnmanaged(sema.Type),

    /// Reused for SymIds.
    tempSyms: std.ArrayListUnmanaged(sema.ResolvedSymId),

    deinitedRtObjects: bool,

    pub fn init(self: *VMcompiler, vm: *cy.VM) !void {
        self.* = .{
            .alloc = vm.alloc,
            .vm = vm,
            .buf = try cy.ByteCodeBuffer.init(vm.alloc),
            .lastErr = "",
            .lastErrNode = undefined,
            .lastErrChunk = undefined,
            .errorPayload = undefined,
            .sema = sema.Model.init(),
            .chunks = .{},
            .importTasks = .{},
            .moduleLoaders = .{},
            .deinitedRtObjects = false,
            .tempTypes = .{},
            .tempSyms = .{},
            .typeStack = .{},
        };
        try self.addModuleLoader("core", initModuleCompat("core", core_mod.initModule));
        try self.addModuleLoader("math", initModuleCompat("math", math_mod.initModule));
        try self.addModuleLoader("os", initModuleCompat("os", os_mod.initModule));
        try self.addModuleLoader("test", initModuleCompat("test", test_mod.initModule));

        try self.reinit();    
    }

    pub fn deinitRtObjects(self: *VMcompiler) void {
        if (self.deinitedRtObjects) {
            return;
        }
        if (self.sema.moduleMap.get("os")) |id| {
            os_mod.deinitModule(self, self.sema.modules.items[id]) catch stdx.fatal();
        }
        self.deinitedRtObjects = true;
    }

    pub fn deinit(self: *VMcompiler, comptime reset: bool) void {
        self.alloc.free(self.lastErr);

        if (reset) {
            self.buf.clear();
        } else {
            self.buf.deinit();
        }

        self.deinitRtObjects();
        self.sema.deinit(self.alloc, reset);

        for (self.chunks.items) |*chunk| {
            chunk.deinit();
        }
        if (reset) {
            self.chunks.clearRetainingCapacity();
            self.importTasks.clearRetainingCapacity();
        } else {
            self.chunks.deinit(self.alloc);
            self.importTasks.deinit(self.alloc);
        }

        if (reset) {
            // `moduleLoaders` persists.
        } else {
            var iter = self.moduleLoaders.iterator();
            while (iter.next()) |e| {
                self.alloc.free(e.key_ptr.*);
                e.value_ptr.deinit(self.alloc);
            }
            self.moduleLoaders.deinit(self.alloc);
        }

        if (reset) {
            self.typeStack.clearRetainingCapacity();
            self.tempTypes.clearRetainingCapacity();
            self.tempSyms.clearRetainingCapacity();
        } else {
            self.typeStack.deinit(self.alloc);
            self.tempTypes.deinit(self.alloc);
            self.tempSyms.deinit(self.alloc);
        }
    }

    pub fn reinit(self: *VMcompiler) !void {
        self.deinitedRtObjects = false;
        self.lastErrNode = cy.NullId;
        self.lastErrChunk = cy.NullId;

        var id = try sema.ensureNameSym(self, "any");
        std.debug.assert(id == sema.NameAny);
        id = try sema.ensureNameSym(self, "number");
        std.debug.assert(id == sema.NameNumber);
        id = try sema.ensureNameSym(self, "int");
        std.debug.assert(id == sema.NameInt);
        id = try sema.ensureNameSym(self, "taglit");
        std.debug.assert(id == sema.NameTagLiteral);

        // Add builtins types as resolved syms.
        id = try sema.addResolvedBuiltinSym(self, .any, "any");
        std.debug.assert(id == sema.ResolvedSymAny);
        id = try sema.addResolvedBuiltinSym(self, .int, "number");
        std.debug.assert(id == sema.ResolvedSymNumber);
        id = try sema.addResolvedBuiltinSym(self, .int, "int");
        std.debug.assert(id == sema.ResolvedSymInt);
        id = try sema.addResolvedBuiltinSym(self, .int, "taglit");
        std.debug.assert(id == sema.ResolvedSymTagLiteral);
        id = try sema.addResolvedBuiltinSym(self, .list, "list");
        std.debug.assert(id == sema.ResolvedSymList);
        id = try sema.addResolvedBuiltinSym(self, .boolean, "boolean");
        std.debug.assert(id == sema.ResolvedSymBoolean);
        id = try sema.addResolvedBuiltinSym(self, .string, "string");
        std.debug.assert(id == sema.ResolvedSymString);
        id = try sema.addResolvedBuiltinSym(self, .map, "map");
        std.debug.assert(id == sema.ResolvedSymMap);
    }

    pub fn compile(self: *VMcompiler, srcUri: []const u8, src: []const u8, config: CompileConfig) !CompileResultView {
        self.compileInner(srcUri, src, config) catch |err| {
            if (err == error.TokenError) {
                return CompileResultView{
                    .buf = self.buf,
                    .err = .tokenize,
                };
            } else if (err == error.ParseError) {
                return CompileResultView{
                    .buf = self.buf,
                    .err = .parse,
                };
            } else {
                if (dumpCompileErrorStackTrace and !cy.silentError) {
                    std.debug.dumpStackTrace(@errorReturnTrace().?.*);
                }
                if (err != error.CompileError) {
                    if (self.chunks.items.len > 0) {
                        // Report other errors using the main chunk.
                        const chunk = &self.chunks.items[0];
                        try chunk.setErrorAt("Error: {}", &.{v(err)}, cy.NullId);
                    } else {
                        return err;
                    }
                }
                return CompileResultView{
                    .buf = self.buf,
                    .err = .compile,
                };
            }
        };
        return CompileResultView{
            .buf = self.buf,
            .err = null,
        };
    }

    /// Wrap compile so all errors can be handled in one place.
    fn compileInner(self: *VMcompiler, srcUri: []const u8, src: []const u8, config: CompileConfig) !void {
        var finalSrcUri: []const u8 = undefined;
        if (!cy.isWasm and self.vm.config.enableFileModules) {
            // Ensure that `srcUri` is resolved.
            finalSrcUri = std.fs.cwd().realpathAlloc(self.alloc, srcUri) catch |err| {
                log.debug("Could not resolve main src uri: {s}", .{srcUri});
                return err;
            };
        } else {
            finalSrcUri = try self.alloc.dupe(u8, srcUri);
        }
        defer {
            self.alloc.free(finalSrcUri);
        }

        // Main chunk.
        const mainModId = try sema.appendRootModule(self, finalSrcUri);
        const mainMod = self.sema.getModulePtr(mainModId);
        const nextId = @intCast(u32, self.chunks.items.len);
        var mainChunk = try CompileChunk.init(self, nextId, mainMod.absSpec, src);
        mainChunk.modId = mainModId;
        mainMod.chunkId = nextId;
        try self.chunks.append(self.alloc, mainChunk);

        // Load core module first since the members are imported into each user module.
        const coreModId = try sema.appendRootModule(self, "core");
        const importCore = ImportTask{
            .chunkId = nextId,
            .nodeId = cy.NullId,
            .absSpec = "core",
            .modId = coreModId,
            .builtin = true,
        };
        try performImportTask(self, importCore);

        // All modules and data types are loaded first.
        var id: u32 = 0;
        while (true) {
            while (id < self.chunks.items.len) : (id += 1) {
                log.debug("chunk parse: {}", .{id});
                try self.performChunkParse(id);

                const chunk = &self.chunks.items[id];
                const mod = self.sema.getModule(chunk.modId);
                chunk.semaResolvedRootSymId = mod.resolvedRootSymId;

                // Process static declarations.
                for (chunk.parser.staticDecls.items) |decl| {
                    switch (decl.declT) {
                        .import => {
                            try sema.declareImport(chunk, decl.inner.import);
                        },
                        .object => {
                            try sema.declareObject(chunk, decl.inner.object);
                        },
                        .typeAlias => {
                            try sema.declareTypeAlias(chunk, decl.inner.typeAlias);
                        },
                        .variable,
                        .func,
                        .funcInit => {},
                    }
                }
            }
            // Check for import tasks.
            for (self.importTasks.items) |task| {
                try self.performImportTask(task);
            }
            self.importTasks.clearRetainingCapacity();
            if (id == self.chunks.items.len) {
                // No more chunks were added from import tasks.
                break;
            }
        }

        // Declare static vars and funcs after types have been resolved.
        id = 0;
        while (id < self.chunks.items.len) : (id += 1) {
            const chunk = &self.chunks.items[id];

            // Import core module into local namespace.
            const modId = try sema.getOrLoadModule(chunk, "core", cy.NullId);
            try sema.importAllFromModule(chunk, modId);

            // Process static declarations.
            for (chunk.parser.staticDecls.items) |decl| {
                switch (decl.declT) {
                    .variable => {
                        try sema.declareVar(chunk, decl.inner.variable);
                    },
                    .func => {
                        try sema.declareFunc(chunk, decl.inner.func);
                    },
                    .funcInit => {
                        try sema.declareFuncInit(chunk, decl.inner.funcInit);
                    },
                    .object => {
                        try sema.declareObjectMembers(chunk, decl.inner.object);
                    },
                    .import,
                    .typeAlias => {},
                }
            }
        }

        // Perform sema on all chunks.
        id = 0;
        while (id < self.chunks.items.len) : (id += 1) {
            try self.performChunkSema(id);
        }
        
        // Set up for genVarDecls.
        // All main blocks should be initialized since genVarDecls can alternate chunks.
        for (self.chunks.items) |*chunk| {
            try chunk.pushSemaBlock(chunk.mainSemaBlockId);
            chunk.buf = &self.buf;
            // Temp locals can start at 0 for initializers codegen.
            chunk.curBlock.numLocals = 0;
        }

        if (!config.skipCodegen) {
            // Once all symbols have been resolved, the static initializers are generated in DFS order.
            for (self.chunks.items) |*chunk| {
                log.debug("gen static initializer for chunk: {}", .{chunk.id});

                for (chunk.parser.staticDecls.items) |decl| {
                    if (decl.declT == .variable) {
                        const node = chunk.nodes[decl.inner.variable];
                        const rSymId = node.head.varDecl.sema_rSymId;
                        const crSymId = sema.CompactResolvedSymId.initSymId(rSymId);
                        try gen.genStaticInitializerDFS(chunk, crSymId);
                    } else if (decl.declT == .funcInit) {
                        const node = chunk.nodes[decl.inner.funcInit];
                        const declId = node.head.func.semaDeclId;
                        const func = chunk.semaFuncDecls.items[declId];
                        const crSymId = sema.CompactResolvedSymId.initFuncSymId(func.rFuncSymId);
                        try gen.genStaticInitializerDFS(chunk, crSymId);
                    }
                }
                chunk.resetNextFreeTemp();
            }

            for (self.chunks.items, 0..) |*chunk, i| {
                log.debug("perform codegen for chunk: {}", .{i});
                try self.performChunkCodegen(chunk.id);
            }

            // Merge inst and const buffers.
            var reqLen = self.buf.ops.items.len + self.buf.consts.items.len * @sizeOf(cy.Const) + @alignOf(cy.Const) - 1;
            if (self.buf.ops.capacity < reqLen) {
                try self.buf.ops.ensureTotalCapacityPrecise(self.alloc, reqLen);
            }
            const constAddr = std.mem.alignForward(@ptrToInt(self.buf.ops.items.ptr) + self.buf.ops.items.len, @alignOf(cy.Const));
            const constDst = @intToPtr([*]cy.Const, constAddr)[0..self.buf.consts.items.len];
            const constSrc = try self.buf.consts.toOwnedSlice(self.alloc);
            std.mem.copy(cy.Const, constDst, constSrc);
            self.alloc.free(constSrc);
            self.buf.mconsts = constDst;
        }

        // Final op address is known. Patch pc offsets.
        // for (self.vm.funcSyms.items()) |*sym| {
        //     if (sym.entryT == .func) {
        //         sym.inner.func.pc = .{ .ptr = self.buf.ops.items.ptr + sym.inner.func.pc.offset};
        //     }
        // }
        // for (self.vm.methodSyms.items()) |*sym| {
        //     if (sym.mapT == .one) {
        //         if (sym.inner.one.sym.entryT == .func) {
        //             sym.inner.one.sym.inner.func.pc = .{ .ptr = self.buf.ops.items.ptr + sym.inner.one.sym.inner.func.pc.offset };
        //         }
        //     } else if (sym.mapT == .many) {
        //         if (sym.inner.many.mruSym.entryT == .func) {
        //             sym.inner.many.mruSym.inner.func.pc = .{ .ptr = self.buf.ops.items.ptr + sym.inner.many.mruSym.inner.func.pc.offset };
        //         }
        //     }
        // }
        // var iter = self.vm.methodTable.iterator();
        // while (iter.next()) |entry| {
        //     const sym = entry.value_ptr;
        //     if (sym.entryT == .func) {
        //         sym.inner.func.pc = .{ .ptr = self.buf.ops.items.ptr + sym.inner.func.pc.offset };
        //     }
        // }
    }

    /// Sema pass.
    /// Symbol resolving, type checking, and builds the model for codegen.
    fn performChunkSema(self: *VMcompiler, id: CompileChunkId) !void {
        const chunk = &self.chunks.items[id];

        // Dummy first element to avoid len > 0 check during pop.
        try chunk.semaSubBlocks.append(self.alloc, sema.SubBlock.init(0, 0));
        try chunk.semaBlockStack.append(self.alloc, 0);

        const root = chunk.nodes[chunk.parserAstRootId];

        chunk.mainSemaBlockId = try sema.pushBlock(chunk, cy.NullId);
        sema.semaStmts(chunk, root.head.root.headStmt, true) catch |err| {
            try sema.endBlock(chunk);
            return err;
        };
        try sema.endBlock(chunk);
    }

    /// Tokenize and parse.
    /// Parser pass collects static declaration info.
    fn performChunkParse(self: *VMcompiler, id: CompileChunkId) !void {
        const chunk = &self.chunks.items[id];

        var tt = stdx.debug.trace();
        const ast = try chunk.parser.parse(chunk.src);
        tt.endPrint("parse");
        // Update buffer pointers so success/error paths can access them.
        chunk.nodes = ast.nodes.items;
        chunk.tokens = ast.tokens;
        if (ast.has_error) {
            self.lastErrChunk = id;
            if (ast.isTokenError) {
                return error.TokenError;
            } else {
                return error.ParseError;
            }
        }
        chunk.parserAstRootId = ast.root_id;
    }

    fn performChunkCodegen(self: *VMcompiler, id: CompileChunkId) !void {
        const chunk = &self.chunks.items[id];

        if (id == 0) {
            // Main script performs gen for decls and the main block.
            try gen.genInitLocals(chunk);
            const jumpStackStart = chunk.blockJumpStack.items.len;
            const root = chunk.nodes[0];
            try gen.genStatements(chunk, root.head.root.headStmt, true);
            chunk.patchBlockJumps(jumpStackStart);
            chunk.blockJumpStack.items.len = jumpStackStart;
            chunk.popBlock();
            self.buf.mainStackSize = @intCast(u32, chunk.curBlock.getRequiredStackSize());
        } else {
            // Modules perform gen for only the top level declarations.
            const root = chunk.nodes[0];
            try gen.genTopDeclStatements(chunk, root.head.root.headStmt);
            chunk.popBlock();
        }
    }

    fn performImportTask(self: *VMcompiler, task: ImportTask) !void {
        if (task.builtin) {
            if (self.moduleLoaders.get(task.absSpec)) |loaders| {
                const mod = self.sema.getModulePtr(task.modId);
                for (loaders.items) |loader| {
                    if (!loader(@ptrCast(*cy.UserVM, self.vm), mod)) {
                        return error.LoadModuleError;
                    }
                }
            } else {
                const chunk = &self.chunks.items[task.chunkId];
                return chunk.reportErrorAt("Unsupported builtin. {}", &.{fmt.v(task.absSpec)}, task.nodeId);
            }
        } else {
            // Default loader.

            if (cy.isWasm) {
                return error.Unsupported;
            }

            var src: []const u8 = undefined;
            if (std.mem.startsWith(u8, task.absSpec, "http://") or std.mem.startsWith(u8, task.absSpec, "https://")) {
                src = try self.importUrl(task);
            } else {
                src = try std.fs.cwd().readFileAlloc(self.alloc, task.absSpec, 1e10);
            }

            // Push another chunk.
            const newChunkId = @intCast(u32, self.chunks.items.len);
            var newChunk = try CompileChunk.init(self, newChunkId, task.absSpec, src);
            newChunk.srcOwned = true;
            newChunk.modId = task.modId;

            try self.chunks.append(self.alloc, newChunk);
            self.sema.modules.items[task.modId].chunkId = newChunkId;
        }
    }

    pub fn addModuleLoader(self: *VMcompiler, absSpec: []const u8, func: cy.ModuleLoaderFunc) !void {
        const res = try self.moduleLoaders.getOrPut(self.alloc, absSpec);
        if (res.found_existing) {
            const list = res.value_ptr;
            try list.append(self.alloc, func);
        } else {
            const keyDupe = try self.alloc.dupe(u8, absSpec);
            // Start with initial cap = 1.
            res.value_ptr.* = try std.ArrayListUnmanaged(cy.ModuleLoaderFunc).initCapacity(self.alloc, 1);
            res.key_ptr.* = keyDupe;
            const list = res.value_ptr;
            list.items.len = 1;
            list.items[0] = func;
        }
    }

    fn importUrl(self: *VMcompiler, task: ImportTask) ![]const u8 {
        const specGroup = try cache.getSpecHashGroup(self.alloc, task.absSpec);
        defer specGroup.deinit(self.alloc);

        if (self.vm.config.reload) {
            // Remove cache entry.
            try specGroup.markEntryBySpecForRemoval(task.absSpec);
        } else {
            // First check local cache.
            if (try specGroup.findEntryBySpec(task.absSpec)) |entry| {
                var found = true;
                const src = cache.allocSpecFileContents(self.alloc, entry) catch |err| b: {
                    if (err == error.FileNotFound) {
                        // Fallthrough.
                        found = false;
                        break :b "";
                    } else {
                        return err;
                    }
                };
                if (found) {
                    log.debug("Using cached {s}", .{task.absSpec});
                    return src;
                }
            }
        }

        const client = self.vm.httpClient;

        const uri = try std.Uri.parse(task.absSpec);
        var req = client.request(uri) catch |err| {
            if (err == error.UnknownHostName) {
                const chunk = &self.chunks.items[task.chunkId];
                const stmt = chunk.nodes[task.nodeId];
                return chunk.reportErrorAt("Can not connect to `{}`.", &.{v(uri.host.?)}, stmt.head.left_right.right);
            } else {
                return err;
            }
        };
        defer req.deinit();

        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(self.alloc);
        var readBuf: [4096]u8 = undefined;

        // First read should consume the status code.
        var read = try client.readAll(&req, &readBuf);
        try buf.appendSlice(self.alloc, readBuf[0..read]);

        switch (req.response.headers.status) {
            .ok => {
                // Whitelisted status codes.
            },
            else => {
                // Stop immediately.
                const chunk = &self.chunks.items[task.chunkId];
                const stmt = chunk.nodes[task.nodeId];
                return chunk.reportErrorAt("Can not load `{}`. Response code: {}", &.{v(task.absSpec), v(req.response.headers.status)}, stmt.head.left_right.right);
            },
        }

        while (read > 0) {
            read = try client.readAll(&req, &readBuf);
            try buf.appendSlice(self.alloc, readBuf[0..read]);
        }

        // Cache to local.
        const entry = try cache.saveNewSpecFile(self.alloc, specGroup, task.absSpec, buf.items);
        entry.deinit(self.alloc);

        return try buf.toOwnedSlice(self.alloc);
    }
};

pub const CompileErrorType = enum {
    tokenize,
    parse,
    compile,
};

pub const CompileResultView = struct {
    buf: cy.ByteCodeBuffer,
    err: ?CompileErrorType,
};

const VarInfo = struct {
    hasStaticType: bool,
};

const Load = struct {
    pc: u32,
    tempOffset: u8,
};

// Same as std.mem.replace except writes to an ArrayList. Final result is also known to be at most the size of the original.
pub fn replaceIntoShorterList(comptime T: type, input: []const T, needle: []const T, replacement: []const T, output: *std.ArrayListUnmanaged(T), alloc: std.mem.Allocator) !usize {
    // Known upper bound.
    try output.resize(alloc, input.len);
    var i: usize = 0;
    var slide: usize = 0;
    var replacements: usize = 0;
    while (slide < input.len) {
        if (std.mem.indexOf(T, input[slide..], needle) == @as(usize, 0)) {
            std.mem.copy(u8, output.items[i..i+replacement.len], replacement);
            i += replacement.len;
            slide += needle.len;
            replacements += 1;
        } else {
            output.items[i] = input[slide];
            i += 1;
            slide += 1;
        }
    }
    output.items.len = i;
    return replacements;
}

/// Some nodes will always retain in order to behave correctly under ARC.
/// The temp register allocator needs to know this ahead of time to determine the dst register.
fn genWillAlwaysRetainNode(c: *CompileChunk, node: cy.Node) bool {
    switch (node.node_t) {
        .callExpr,
        .arr_literal,
        .map_literal,
        .stringTemplate,
        .arr_access_expr,
        .coinit,
        .objectInit => return true,
        .accessExpr => {
            if (node.head.accessExpr.sema_crSymId.isPresent()) {
                if (willAlwaysRetainResolvedSym(c, node.head.accessExpr.sema_crSymId)) {
                    return true;
                }
            }
            return false;
        },
        .ident => {
            if (node.head.ident.semaVarId != cy.NullId) {
                const svar = c.genGetVar(node.head.ident.semaVarId).?;
                if (svar.isStaticAlias) {
                    if (willAlwaysRetainResolvedSym(c, svar.inner.staticAlias.crSymId)) {
                        return true;
                    }
                }
            }
            if (node.head.ident.sema_crSymId.isPresent()) {
                if (willAlwaysRetainResolvedSym(c, node.head.ident.sema_crSymId)) {
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

fn willAlwaysRetainResolvedSym(c: *CompileChunk, crSymId: sema.CompactResolvedSymId) bool {
    if (crSymId.isFuncSymId) {
        // `staticFunc` op is always retained.
        return true;
    } else {
        const rSym = c.compiler.sema.getResolvedSym(crSymId.id);
        if (rSym.symT == .variable) {
            // Since `staticVar` op is always retained atm.
            return true;
        } else if (rSym.symT == .object) {
            // `sym` op is always retained.
            return true;
        }
    }
    return false;
}

/// `buf` is assumed to be big enough.
pub fn unescapeString(buf: []u8, literal: []const u8) []const u8 {
    var newIdx: u32 = 0; 
    var i: u32 = 0;
    while (i < literal.len) : (newIdx += 1) {
        if (literal[i] == '\\') {
            switch (literal[i + 1]) {
                'a' => {
                    buf[newIdx] = 0x07;
                },
                'b' => {
                    buf[newIdx] = 0x08;
                },
                'e' => {
                    buf[newIdx] = 0x1b;
                },
                'n' => {
                    buf[newIdx] = '\n';
                },
                'r' => {
                    buf[newIdx] = '\r';
                },
                't' => {
                    buf[newIdx] = '\t';
                },
                else => {
                    buf[newIdx] = literal[i + 1];
                }
            }
            i += 2;
        } else {
            buf[newIdx] = literal[i];
            i += 1;
        }
    }
    return buf[0..newIdx];
}

const ReservedTempLocal = struct {
    local: LocalId,
};

const unexpected = stdx.fatal;

const DataNode = packed struct {
    inner: packed union {
        funcSym: packed struct {
            symId: u32,
        },
    },
    next: u32,
};

const CompileChunkId = u32;

/// A compilation unit.
/// It contains data to compile from source into a module with exported symbols.
pub const CompileChunk = struct {
    id: CompileChunkId,
    alloc: std.mem.Allocator,
    compiler: *VMcompiler,

    /// Source code.
    src: []const u8,

    /// Absolute path to source.
    srcUri: []const u8,

    parser: cy.Parser,
    parserAstRootId: cy.NodeId,

    /// Generic linked list buffer.
    dataNodes: std.ArrayListUnmanaged(DataNode),

    /// Used for temp string building.
    tempBufU8: std.ArrayListUnmanaged(u8),

    /// Since nodes are currently processed recursively,
    /// set the current node so that error reporting has a better
    /// location context for helper methods that simply return no context errors.
    curNodeId: cy.NodeId,

    ///
    /// Sema pass
    ///
    semaBlocks: std.ArrayListUnmanaged(sema.Block),
    semaSubBlocks: std.ArrayListUnmanaged(sema.SubBlock),
    vars: std.ArrayListUnmanaged(sema.LocalVar),
    capVarDescs: std.AutoHashMapUnmanaged(sema.LocalVarId, sema.CapVarDesc),

    /// Local paths to syms.
    semaSyms: std.ArrayListUnmanaged(sema.Sym),
    semaSymMap: std.HashMapUnmanaged(sema.AbsLocalSymKey, sema.SymId, vm_.KeyU128Context, 80),

    /// List of func decls.
    /// They are resolved after data types.
    semaFuncDecls: std.ArrayListUnmanaged(sema.FuncDecl),

    /// Track first nodes that use the symbol for error reporting.
    /// TODO: Remove.
    semaSymFirstNodes: std.ArrayListUnmanaged(cy.NodeId),

    /// Additional info for initializer symbols.
    semaInitializerSyms: std.AutoArrayHashMapUnmanaged(sema.CompactResolvedSymId, sema.InitializerSym),

    assignedVarStack: std.ArrayListUnmanaged(sema.LocalVarId),
    curSemaBlockId: sema.BlockId,
    curSemaSubBlockId: sema.SubBlockId,

    /// Which sema sym var is currently being analyzed for an assignment initializer.
    curSemaInitingSym: sema.CompactResolvedSymId,

    /// When looking at a var declaration, keep track of which symbols are already recorded as dependencies.
    semaVarDeclDeps: std.AutoHashMapUnmanaged(sema.CompactResolvedSymId, void),

    /// Currently used to store lists of static var dependencies.
    bufU32: std.ArrayListUnmanaged(u32),

    /// The resolved sym id of this chunk.
    semaResolvedRootSymId: sema.ResolvedSymId,

    /// Current block stack.
    semaBlockStack: std.ArrayListUnmanaged(sema.BlockId),

    /// Main sema block id.
    mainSemaBlockId: sema.BlockId,

    /// Local syms is used as a cache to sema.resolvedSyms.
    /// It's useful to store imports, importAlls that are only visible to the module.
    localSyms: std.HashMapUnmanaged(sema.RelLocalSymKey, sema.LocalSym, vm_.KeyU64Context, 80),

    ///
    /// Codegen pass
    ///
    blocks: std.ArrayListUnmanaged(GenBlock),
    blockJumpStack: std.ArrayListUnmanaged(BlockJump),
    subBlockJumpStack: std.ArrayListUnmanaged(SubBlockJump),

    /// Tracks which temp locals are reserved. They are skipped for temp local allocations.
    reservedTempLocalStack: std.ArrayListUnmanaged(ReservedTempLocal),

    operandStack: std.ArrayListUnmanaged(cy.OpData),

    /// Used to advance to the next saved sema sub block.
    nextSemaSubBlockId: u32,
    curBlock: *GenBlock,

    /// Shared code buffer.
    buf: *cy.ByteCodeBuffer,

    nodes: []cy.Node,
    tokens: []const cy.Token,

    /// Whether the src is owned by the chunk.
    srcOwned: bool,

    /// Points to this chunk's `Module`.
    /// Its exported members will be populated in the Module as sema encounters them.
    modId: sema.ModuleId,

    fn init(c: *VMcompiler, id: CompileChunkId, srcUri: []const u8, src: []const u8) !CompileChunk {
        var new = CompileChunk{
            .id = id,
            .alloc = c.alloc,
            .compiler = c,
            .src = src,
            .srcUri = srcUri,
            .parser = cy.Parser.init(c.alloc),
            .parserAstRootId = cy.NullId,
            .nodes = undefined,
            .tokens = undefined,
            .semaBlocks = .{},
            .semaSubBlocks = .{},
            .semaSyms = .{},
            .semaSymMap = .{},
            .semaSymFirstNodes = .{},
            .semaInitializerSyms = .{},
            .vars = .{},
            .capVarDescs = .{},
            .blocks = .{},
            .blockJumpStack = .{},
            .subBlockJumpStack = .{},
            .reservedTempLocalStack = .{},
            .assignedVarStack = .{},
            .operandStack = .{},
            .curBlock = undefined,
            .curSemaBlockId = undefined,
            .curSemaSubBlockId = undefined,
            .nextSemaSubBlockId = undefined,
            .buf = undefined,
            .curNodeId = cy.NullId,
            .curSemaInitingSym = @bitCast(sema.CompactResolvedSymId, @as(u32, cy.NullId)),
            .semaVarDeclDeps = .{},
            .bufU32 = .{},
            .dataNodes = .{},
            .tempBufU8 = .{},
            .srcOwned = false,
            .modId = cy.NullId,
            .semaResolvedRootSymId = cy.NullId,
            .semaBlockStack = .{},
            .mainSemaBlockId = cy.NullId,
            .semaFuncDecls = .{},
            .localSyms = .{},
        };
        try new.parser.tokens.ensureTotalCapacityPrecise(c.alloc, 511);
        try new.parser.nodes.ensureTotalCapacityPrecise(c.alloc, 127);
        return new;
    }

    fn deinit(self: *CompileChunk) void {
        self.tempBufU8.deinit(self.alloc);

        for (self.semaSubBlocks.items) |*block| {
            block.deinit(self.alloc);
        }
        self.semaSubBlocks.deinit(self.alloc);

        for (self.semaBlocks.items) |*sblock| {
            sblock.deinit(self.alloc);
        }
        self.semaBlocks.deinit(self.alloc);
        self.semaBlockStack.deinit(self.alloc);

        self.blocks.deinit(self.alloc);

        self.bufU32.deinit(self.alloc);
        self.semaVarDeclDeps.deinit(self.alloc);
        self.dataNodes.deinit(self.alloc);

        self.blockJumpStack.deinit(self.alloc);
        self.subBlockJumpStack.deinit(self.alloc);
        self.assignedVarStack.deinit(self.alloc);
        self.operandStack.deinit(self.alloc);
        self.reservedTempLocalStack.deinit(self.alloc);
        self.vars.deinit(self.alloc);
        self.capVarDescs.deinit(self.alloc);

        self.semaSyms.deinit(self.alloc);
        self.semaSymMap.deinit(self.alloc);
        self.semaSymFirstNodes.deinit(self.alloc);
        self.semaInitializerSyms.deinit(self.alloc);

        self.parser.deinit();
        if (self.srcOwned) {
            self.alloc.free(self.src);
        }

        self.semaFuncDecls.deinit(self.alloc);
        self.localSyms.deinit(self.alloc);
    }

    pub inline fn isInStaticInitializer(self: *CompileChunk) bool {
        return self.curSemaInitingSym.isPresent();
    }

    /// Assumes `semaBlockStack` has a dummy head element. Main block starts at 1.
    pub inline fn semaBlockDepth(self: *CompileChunk) u32 {
        return @intCast(u32, self.semaBlockStack.items.len-1);
    }

    pub fn pushSemaBlock(self: *CompileChunk, id: sema.BlockId) !void {
        // Codegen block should be pushed first so nextSemaSubBlock can use it.
        try self.pushBlock();

        try self.semaBlockStack.append(self.alloc, id);
        self.curSemaBlockId = id;
        self.nextSemaSubBlockId = self.semaBlocks.items[id].firstSubBlockId;
        self.nextSemaSubBlock();
    }

    pub fn popSemaBlock(self: *CompileChunk) void {
        self.semaBlockStack.items.len -= 1;
        self.curSemaBlockId = self.semaBlockStack.items[self.semaBlockStack.items.len-1];
        self.prevSemaSubBlock();

        self.popBlock();
    }

    pub fn reserveIfTempLocal(self: *CompileChunk, local: LocalId) !void {
        if (self.isTempLocal(local)) {
            try self.setReservedTempLocal(local);
        }
    }

    pub fn setReservedTempLocal(self: *CompileChunk, local: LocalId) !void {
        // log.debug("set reserved {}", .{self.reservedTempLocalStack.items.len});
        try self.reservedTempLocalStack.append(self.alloc, .{
            .local = local,
        });
    }

    pub fn canUseLocalAsTemp(self: *const CompileChunk, local: LocalId) bool {
        if (self.blocks.items.len > 1) {
            // Temp or return slot.
            return local == 0 or local >= self.curBlock.numLocals;
        } else {
            // For main block, it can only use local as a temporary if it's in fact a temp.
            return local >= self.curBlock.numLocals;
        }
    }

    pub inline fn isTempLocal(self: *const CompileChunk, local: LocalId) bool {
        return local >= self.curBlock.numLocals;
    }

    pub fn initGenValue(self: *const CompileChunk, local: LocalId, vtype: sema.Type, retained: bool) gen.GenValue {
        if (self.isTempLocal(local)) {
            return gen.GenValue.initTempValue(local, vtype, retained);
        } else {
            return gen.GenValue.initLocalValue(local, vtype, retained);
        }
    }

    /// TODO: Rename to reserveNextTempLocal.
    /// Assumes that if `firstFreeTempLocal` is in bounds, it is free.
    pub fn nextFreeTempLocal(self: *CompileChunk) !LocalId {
        if (self.curBlock.firstFreeTempLocal < 256) {
            if (self.curBlock.firstFreeTempLocal == self.curBlock.numLocals + self.curBlock.numTempLocals) {
                self.curBlock.numTempLocals += 1;
            }
            defer {
                // Advance to the next free temp considering reserved arc temps.
                self.computeNextTempLocalFrom(self.curBlock.firstFreeTempLocal + 1);
            }
            return @intCast(u8, self.curBlock.firstFreeTempLocal);
        } else {
            return self.reportError("Exceeded max locals.", &.{});
        }
    }

    pub fn computeNextTempLocalFrom(self: *CompileChunk, local: LocalId) void {
        self.curBlock.firstFreeTempLocal = local;
        if (self.curBlock.reservedTempLocalStart < self.reservedTempLocalStack.items.len) {
            while (self.isReservedTempLocal(self.curBlock.firstFreeTempLocal)) {
                self.curBlock.firstFreeTempLocal += 1;
            }
        }
    }

    /// Find first available temp starting from the beginning.
    pub fn resetNextFreeTemp(self: *CompileChunk) void {
        self.computeNextTempLocalFrom(@intCast(u8, self.curBlock.numLocals));
    }

    pub fn setFirstFreeTempLocal(self: *CompileChunk, local: LocalId) void {
        self.curBlock.firstFreeTempLocal = local;
    }

    /// Given two local values, determine the next destination temp local.
    /// The type of the dest value is left undefined to be set by caller.
    fn nextTempDestValue(self: *VMcompiler, src1: gen.GenValue, src2: gen.GenValue) !gen.GenValue {
        if (src1.isTempLocal == src2.isTempLocal) {
            if (src1.isTempLocal) {
                const minTempLocal = std.math.min(src1.local, src2.local);
                self.setFirstFreeTempLocal(minTempLocal + 1);
                return gen.GenValue.initTempValue(minTempLocal, undefined);
            } else {
                return gen.GenValue.initTempValue(try self.nextFreeTempLocal(), undefined);
            }
        } else {
            if (src1.isTempLocal) {
                return gen.GenValue.initTempValue(src1.local, undefined);
            } else {
                return gen.GenValue.initTempValue(src2.local, undefined);
            }
        }
    }

    pub fn genExpr(self: *CompileChunk, nodeId: cy.NodeId, comptime discardTopExprReg: bool) anyerror!gen.GenValue {
        self.curNodeId = nodeId;
        return self.genExpr2(nodeId, sema.AnyType, discardTopExprReg);
    }

    /// If the expression is a user local, the local is returned.
    /// Otherwise, the expression is allocated a temp local on the stack.
    fn genExpr2(self: *CompileChunk, nodeId: cy.NodeId, requiredType: sema.Type, comptime discardTopExprReg: bool) anyerror!gen.GenValue {
        const dst = try self.userLocalOrNextTempLocal(nodeId);
        const res = try gen.genExprTo2(self, nodeId, dst, requiredType, false, !discardTopExprReg);
        try self.genEnsureRequiredType(res, requiredType);
        return res;
    }

    pub fn genExprTo(self: *CompileChunk, nodeId: cy.NodeId, dst: LocalId, retainEscapeTop: bool, comptime discardTopExprReg: bool) anyerror!gen.GenValue {
        return gen.genExprTo2(self, nodeId, dst, sema.AnyType, retainEscapeTop, !discardTopExprReg);
    }

    fn genEnsureRequiredType(self: *CompileChunk, genValue: gen.GenValue, requiredType: sema.Type) !void {
        if (requiredType.typeT != .any) {
            if (genValue.vtype.typeT != requiredType.typeT) {
                return self.reportError("Type {} can not be auto converted to required type {}", &.{fmt.v(genValue.vtype.typeT), fmt.v(requiredType.typeT)});
            }
        }
    }

    pub fn genExprPreferLocalOrReplaceableDest(self: *CompileChunk, nodeId: cy.NodeId, dst: LocalId, usedDst: *bool, comptime discardTopExprReg: bool) !gen.GenValue {
        return self.genExprPreferLocalOrReplaceableDest2(sema.AnyType, nodeId, dst, usedDst, discardTopExprReg);
    }

    /// Prefers a local.
    /// Then prefers unused dest if the dest can be replaced without ARC release.
    /// Otherwise, a temp is used.
    pub fn genExprPreferLocalOrReplaceableDest2(self: *CompileChunk, requestedType: sema.Type, nodeId: cy.NodeId, dst: LocalId, usedDst: *bool, comptime discardTopExprReg: bool) !gen.GenValue {
        const node = self.nodes[nodeId];
        if (node.node_t == .ident) {
            if (self.genGetVar(node.head.ident.semaVarId)) |svar| {
                if (canUseVarAsDst(svar)) {
                    return gen.genExprTo2(self, nodeId, svar.local, requestedType, false, !discardTopExprReg);
                }
            }
        }
        if (usedDst.*) {
            const finalDst = try self.nextFreeTempLocal();
            return gen.genExprTo2(self, nodeId, finalDst, requestedType, false, !discardTopExprReg);
        } else {
            // TODO: Handle other expressions that can save to dst.
            var useDst = false;
            switch (node.node_t) {
                .number,
                .false_literal,
                .true_literal => useDst = true,
                else => {}
            }
            if (useDst) {
                usedDst.* = true;
                return gen.genExprTo2(self, nodeId, dst, requestedType, false, !discardTopExprReg);
            } else {
                const finalDst = try self.nextFreeTempLocal();
                return gen.genExprTo2(self, nodeId, finalDst, requestedType, false, !discardTopExprReg);
            }
        }
    }

    pub fn genExprToDestOrTempLocal(self: *CompileChunk, nodeId: cy.NodeId, dst: LocalId, usedDst: *bool, comptime discardTopExprReg: bool) !gen.GenValue {
        return self.genExprToDestOrTempLocal2(sema.AnyType, nodeId, dst, usedDst, discardTopExprReg);
    }

    /// Attempts to gen expression to the destination if it can avoid a retain op.
    /// Otherwise, it is copied to a temp.
    pub fn genExprToDestOrTempLocal2(self: *CompileChunk, requestedType: sema.Type, nodeId: cy.NodeId, dst: LocalId, usedDst: *bool, comptime discardTopExprReg: bool) !gen.GenValue {
        const node = self.nodes[nodeId];
        if (genWillAlwaysRetainNode(self, node) or usedDst.*) {
            const finalDst = try self.userLocalOrNextTempLocal(nodeId);
            return gen.genExprTo2(self, nodeId, finalDst, requestedType, false, !discardTopExprReg);
        } else {
            const finalDst = self.userLocalOrDst(nodeId, dst, usedDst);
            return gen.genExprTo2(self, nodeId, finalDst, requestedType, false, !discardTopExprReg);
        }
    }

    /// Generates an instruction to copy the root expression to a specific destination local.
    /// Also ensures that the expression is retained.
    pub fn genRetainedExprTo(self: *CompileChunk, nodeId: cy.NodeId, dst: LocalId, comptime discardTopExprReg: bool) anyerror!gen.GenValue {
        return try self.genExprTo(nodeId, dst, true, discardTopExprReg);
    }

    pub fn genRetainedTempExpr(self: *CompileChunk, nodeId: cy.NodeId, comptime discardTopExprReg: bool) !gen.GenValue {
        return self.genRetainedTempExpr2(nodeId, sema.AnyType, discardTopExprReg);
    }

    /// Ensures that the expr value is retained and ends up in the next temp local.
    pub fn genRetainedTempExpr2(self: *CompileChunk, nodeId: cy.NodeId, requiredType: sema.Type, comptime discardTopExprReg: bool) anyerror!gen.GenValue {
        const dst = try self.nextFreeTempLocal();
        // ARC temps released at the end of this expr,
        // so the next free temp is guaranteed to be after dst.
        defer self.setFirstFreeTempLocal(dst + 1);

        const val = try gen.genExprTo2(self, nodeId, dst, requiredType, true, !discardTopExprReg);
        try self.genEnsureRequiredType(val, requiredType);
        return val;
    }

    fn isReservedTempLocal(self: *const CompileChunk, local: LocalId) bool {
        for (self.reservedTempLocalStack.items[self.curBlock.reservedTempLocalStart..]) |temp| {
            if (temp.local == local) {
                return true;
            }
        }
        return false;
    }

    fn canUseVarAsDst(svar: sema.LocalVar) bool {
        // If boxed, the var needs to be copied out of the box.
        // If static selected, the var needs to be copied to a local.
        return !svar.isBoxed and !svar.isStaticAlias;
    }

    /// Checks to see if the ident references a local to avoid a copy to dst.
    fn userLocalOrDst(self: *CompileChunk, nodeId: cy.NodeId, dst: LocalId, usedDst: *bool) LocalId {
        if (self.nodes[nodeId].node_t == .ident) {
            if (self.genGetVar(self.nodes[nodeId].head.ident.semaVarId)) |svar| {
                if (canUseVarAsDst(svar)) {
                    return svar.local;
                }
            }
        }
        usedDst.* = true;
        return dst;
    }

    fn userLocalOrNextTempLocal(self: *CompileChunk, nodeId: cy.NodeId) !LocalId {
        const node = self.nodes[nodeId];
        if (node.node_t == .ident) {
            if (self.genGetVar(self.nodes[nodeId].head.ident.semaVarId)) |svar| {
                if (canUseVarAsDst(svar)) {
                    return svar.local;
                }
            }
        } else if (node.node_t == .callExpr) {
            // Since call expr args allocate arg locals past the arc temps,
            // select the call dst to be past the arc temps to skip generating an extra copy op.
            _ = self.advanceNextTempLocalPastReservedTemps();
            return self.nextFreeTempLocal();
        }
        return self.nextFreeTempLocal();
    }

    pub fn advanceNextTempLocalPastReservedTemps(self: *CompileChunk) LocalId {
        if (self.curBlock.reservedTempLocalStart < self.reservedTempLocalStack.items.len) {
            for (self.reservedTempLocalStack.items[self.curBlock.reservedTempLocalStart..]) |temp| {
                if (self.curBlock.firstFreeTempLocal <= temp.local) {
                    self.curBlock.firstFreeTempLocal = temp.local + 1;
                }
            }
        }
        return self.curBlock.firstFreeTempLocal;
    }

    pub fn pushTempOperand(self: *CompileChunk, operand: u8) !void {
        try self.operandStack.append(self.alloc, cy.OpData.initArg(operand));
    }

    pub fn reserveLocal(self: *CompileChunk, block: *GenBlock) !u8 {
        const idx = block.numLocals;
        block.numLocals += 1;
        if (idx <= std.math.maxInt(u8)) {
            return @intCast(u8, idx);
        } else {
            return self.reportError("Exceeded max local count: {}", &.{v(@as(u8, std.math.maxInt(u8)))});
        }
    }

    /// Reserve params and captured vars.
    /// Call convention stack layout:
    /// [startLocal/retLocal] [retInfo] [retAddress] [prevFramePtr] [params...] [callee] [capturedParams...] [locals...]
    pub fn reserveFuncParams(self: *CompileChunk, numParams: u32) !void {
        // First local is reserved for a single return value.
        _ = try self.reserveLocal(self.curBlock);

        // Second local is reserved for the return info.
        _ = try self.reserveLocal(self.curBlock);

        // Third local is reserved for the return address.
        _ = try self.reserveLocal(self.curBlock);

        // Fourth local is reserved for the previous frame pointer.
        _ = try self.reserveLocal(self.curBlock);

        const sblock = sema.curBlock(self);

        // Reserve func params.
        for (sblock.params.items[0..numParams]) |varId| {
            _ = try self.reserveLocalVar(varId);

            // Params are already defined.
            self.vars.items[varId].genIsDefined = true;
        }

        // An extra callee slot is reserved so that function values
        // can call static functions with the same call convention.
        _ = try self.reserveLocal(self.curBlock);

        if (sblock.params.items.len > numParams) {
            for (sblock.params.items[numParams..]) |varId| {
                _ = try self.reserveLocalVar(varId);

                // Params are already defined.
                self.vars.items[varId].genIsDefined = true;
            }
        }
    }

    pub fn genEnsureRtFuncSym(self: *CompileChunk, rFuncSymId: sema.ResolvedFuncSymId) !u32 {
        const rFuncSym = self.compiler.sema.getResolvedFuncSym(rFuncSymId);
        const rSym = self.compiler.sema.getResolvedSym(rFuncSym.getResolvedSymId());
        const key = rSym.key.absResolvedSymKey;
        const rFuncSigId = rFuncSym.getResolvedFuncSigId();
        return self.compiler.vm.ensureFuncSym(key.rParentSymId, key.nameId, rFuncSigId);
    }

    pub fn genGetResolvedFuncSym(self: *const CompileChunk, rSymId: sema.ResolvedSymId, rFuncSigId: sema.ResolvedFuncSigId) ?sema.ResolvedFuncSym {
        const key = sema.AbsResolvedSymKey{
            .absResolvedFuncSymKey = .{
                .rSymId = rSymId,
                .rFuncSigId = rFuncSigId,
            },
        };
        if (self.compiler.semaResolvedFuncSymMap.get(key)) |id| {
            return self.compiler.sema.resolvedFuncSyms.items[id];
        } else {
            return null;
        }
    }

    pub fn genGetResolvedSymId(self: *const CompileChunk, semaSymId: sema.SymId) ?sema.ResolvedSymId {
        const sym = self.semaSyms.items[semaSymId];
        if (sym.rSymId != cy.NullId) {
            return sym.rSymId;
        } else {
            return null;
        }
    }

    pub fn genGetResolvedSym(self: *const CompileChunk, semaSymId: sema.SymId) ?sema.ResolvedSym {
        if (semaSymId != cy.NullId) {
            const sym = self.semaSyms.items[semaSymId];
            if (sym.rSymId != cy.NullId) {
                return self.compiler.sema.resolvedSyms.items[sym.rSymId];
            }
        }
        return null;
    }

    pub fn genBlockEnding(self: *CompileChunk) !void {
        self.curBlock.endLocalsPc = @intCast(u32, self.buf.ops.items.len);
        try self.endLocals();
        if (self.curBlock.requiresEndingRet1) {
            try self.buf.pushOp(.ret1);
        } else {
            try self.buf.pushOp(.ret0);
        }
    }

    pub fn endLocals(self: *CompileChunk) !void {
        const sblock = sema.curBlock(self);

        const start = self.operandStack.items.len;
        defer self.operandStack.items.len = start;

        for (sblock.params.items) |varId| {
            const svar = self.vars.items[varId];
            if (svar.lifetimeRcCandidate and !svar.isCaptured) {
                try self.operandStack.append(self.alloc, cy.OpData.initArg(svar.local));
            }
        }
        for (sblock.locals.items) |varId| {
            const svar = self.vars.items[varId];
            if (svar.lifetimeRcCandidate and svar.genIsDefined) {
                try self.operandStack.append(self.alloc, cy.OpData.initArg(svar.local));
            }
        }
        
        const locals = self.operandStack.items[start..];
        if (locals.len > 0) {
            if (locals.len == 1) {
                try self.buf.pushOp1(.release, locals[0].arg);
            } else {
                try self.buf.pushOp1(.releaseN, @intCast(u8, locals.len));
                try self.buf.pushOperands(locals);
            }
        }
    }

    pub fn pushJumpBackNotNone(self: *CompileChunk, toPc: usize, condLocal: LocalId) !void {
        const pc = self.buf.ops.items.len;
        try self.buf.pushOp3(.jumpNotNone, 0, 0, condLocal);
        self.buf.setOpArgU16(pc + 1, @bitCast(u16, -@intCast(i16, pc - toPc)));
    }

    pub fn pushEmptyJumpNotNone(self: *CompileChunk, condLocal: LocalId) !u32 {
        const start = @intCast(u32, self.buf.ops.items.len);
        try self.buf.pushOp3(.jumpNotNone, 0, 0, condLocal);
        return start;
    }

    pub fn pushEmptyJumpNotCond(self: *CompileChunk, condLocal: LocalId) !u32 {
        const start = @intCast(u32, self.buf.ops.items.len);
        try self.buf.pushOp3(.jumpNotCond, 0, 0, condLocal);
        return start;
    }

    pub fn pushJumpBackCond(self: *CompileChunk, toPc: usize, condLocal: LocalId) !void {
        const pc = self.buf.ops.items.len;
        try self.buf.pushOp3(.jumpCond, 0, 0, condLocal);
        self.buf.setOpArgU16(pc + 1, @bitCast(u16, -@intCast(i16, pc - toPc)));
    }

    pub fn pushJumpBackTo(self: *CompileChunk, toPc: usize) !void {
        const pc = self.buf.ops.items.len;
        try self.buf.pushOp2(.jump, 0, 0);
        self.buf.setOpArgU16(pc + 1, @bitCast(u16, -@intCast(i16, pc - toPc)));
    }

    pub fn pushEmptyJump(self: *CompileChunk) !u32 {
        const start = @intCast(u32, self.buf.ops.items.len);
        try self.buf.pushOp2(.jump, 0, 0);
        return start;
    }

    pub fn pushEmptyJumpCond(self: *CompileChunk, condLocal: LocalId) !u32 {
        const start = @intCast(u32, self.buf.ops.items.len);
        try self.buf.pushOp3(.jumpCond, 0, 0, condLocal);
        return start;
    }

    pub fn patchJumpToCurrent(self: *CompileChunk, jumpPc: u32) void {
        self.buf.setOpArgU16(jumpPc + 1, @intCast(u16, self.buf.ops.items.len - jumpPc));
    }

    /// Patches sub block breaks. For `if` and `match` blocks.
    /// All other jumps are propagated up the stack by copying to the front.
    /// Returns the adjusted jumpStackStart for this block.
    pub fn patchSubBlockBreakJumps(self: *CompileChunk, jumpStackStart: usize, breakPc: usize) usize {
        var propagateIdx = jumpStackStart;
        for (self.subBlockJumpStack.items[jumpStackStart..]) |jump| {
            if (jump.jumpT == .subBlockBreak) {
                self.buf.setOpArgU16(jump.pc + 1, @intCast(u16, breakPc - jump.pc));
            } else {
                self.subBlockJumpStack.items[propagateIdx] = jump;
                propagateIdx += 1;
            }
        }
        return propagateIdx;
    }

    pub fn patchForBlockJumps(self: *CompileChunk, jumpStackStart: usize, breakPc: usize, contPc: usize) void {
        for (self.subBlockJumpStack.items[jumpStackStart..]) |jump| {
            switch (jump.jumpT) {
                .subBlockBreak => {
                    stdx.panicFmt("Unexpected jump.", .{});
                },
                .brk => {
                    if (breakPc > jump.pc) {
                        self.buf.setOpArgU16(jump.pc + 1, @intCast(u16, breakPc - jump.pc));
                    } else {
                        self.buf.setOpArgU16(jump.pc + 1, @bitCast(u16, -@intCast(i16, jump.pc - breakPc)));
                    }
                },
                .cont => {
                    if (contPc > jump.pc) {
                        self.buf.setOpArgU16(jump.pc + 1, @intCast(u16, contPc - jump.pc));
                    } else {
                        self.buf.setOpArgU16(jump.pc + 1, @bitCast(u16, -@intCast(i16, jump.pc - contPc)));
                    }
                },
            }
        }
    }

    pub fn patchBlockJumps(self: *CompileChunk, jumpStackStart: usize) void {
        for (self.blockJumpStack.items[jumpStackStart..]) |jump| {
            switch (jump.jumpT) {
                .jumpToEndLocals => {
                    self.buf.setOpArgU16(jump.pc + jump.pcOffset, @intCast(u16, self.curBlock.endLocalsPc - jump.pc));
                }
            }
        }
    }

    pub fn pushBlock(self: *CompileChunk) !void {
        try self.blocks.append(self.alloc, GenBlock.init());
        self.curBlock = &self.blocks.items[self.blocks.items.len-1];
        self.curBlock.reservedTempLocalStart = @intCast(u32, self.reservedTempLocalStack.items.len);
    }

    pub fn popBlock(self: *CompileChunk) void {
        var last = self.blocks.pop();
        self.reservedTempLocalStack.items.len = last.reservedTempLocalStart;
        last.deinit(self.alloc);
        if (self.blocks.items.len > 0) {
            self.curBlock = &self.blocks.items[self.blocks.items.len-1];
        }
    }

    pub fn blockNumLocals(self: *CompileChunk) usize {
        return sema.curBlock(self).locals.items.len + sema.curBlock(self).params.items.len;
    }

    pub fn genGetVarPtr(self: *const CompileChunk, id: sema.LocalVarId) ?*sema.LocalVar {
        if (id != cy.NullId) {
            return &self.vars.items[id];
        } else {
            return null;
        }
    }

    pub fn genGetVar(self: *const CompileChunk, id: sema.LocalVarId) ?sema.LocalVar {
        if (id != cy.NullId) {
            return self.vars.items[id];
        } else {
            return null;
        }
    }

    pub fn reserveLocalVar(self: *CompileChunk, varId: sema.LocalVarId) !LocalId {
        const local = try self.reserveLocal(self.curBlock);
        self.vars.items[varId].local = local;
        return local;
    }

    pub fn nextSemaSubBlock(self: *CompileChunk) void {
        self.curSemaSubBlockId = self.nextSemaSubBlockId;
        self.nextSemaSubBlockId += 1;

        const ssblock = sema.curSubBlock(self);
        for (ssblock.iterVarBeginTypes.items) |varAndType| {
            const svar = &self.vars.items[varAndType.id];
            // log.debug("{s} iter var", .{self.getVarName(varAndType.id)});
            svar.vtype = varAndType.vtype;
            svar.genIsDefined = true;
        }
    }

    pub fn prevSemaSubBlock(self: *CompileChunk) void {
        self.curSemaSubBlockId = sema.curSubBlock(self).prevSubBlockId;
    }

    pub fn unescapeString(self: *CompileChunk, literal: []const u8) ![]const u8 {
        try self.tempBufU8.resize(self.alloc, literal.len);
        return Root.unescapeString(self.tempBufU8.items, literal);
    }

    pub fn dumpLocals(self: *const CompileChunk, sblock: *sema.Block) !void {
        if (builtin.mode == .Debug and !cy.silentInternal) {
            fmt.printStderr("Locals:\n", &.{});
            for (sblock.params.items) |varId| {
                const svar = self.vars.items[varId];
                fmt.printStderr("{} (param), local: {}, curType: {}, rc: {}, lrc: {}, boxed: {}, cap: {}\n", &.{
                    v(svar.name), v(svar.local), v(svar.vtype.typeT),
                    v(svar.vtype.rcCandidate), v(svar.lifetimeRcCandidate), v(svar.isBoxed), v(svar.isCaptured),
                });
            }
            for (sblock.locals.items) |varId| {
                const svar = self.vars.items[varId];
                fmt.printStderr("{}, local: {}, curType: {}, rc: {}, lrc: {}, boxed: {}, cap: {}\n", &.{
                    v(svar.name), v(svar.local), v(svar.vtype.typeT),
                    v(svar.vtype.rcCandidate), v(svar.lifetimeRcCandidate), v(svar.isBoxed), v(svar.isCaptured),
                });
            }
        }
    }

    fn setErrorAt(self: *CompileChunk, format: []const u8, args: []const fmt.FmtValue, nodeId: cy.NodeId) !void {
        self.alloc.free(self.compiler.lastErr);
        self.compiler.lastErr = try fmt.allocFormat(self.alloc, format, args);
        self.compiler.lastErrNode = nodeId;
        self.compiler.lastErrChunk = self.id;
    }

    pub fn reportError(self: *CompileChunk, format: []const u8, args: []const fmt.FmtValue) error{CompileError, OutOfMemory, FormatError} {
        return self.reportErrorAt(format, args, self.curNodeId);
    }

    pub fn reportErrorAt(self: *CompileChunk, format: []const u8, args: []const fmt.FmtValue, nodeId: cy.NodeId) error{CompileError, OutOfMemory, FormatError} {
        try self.setErrorAt(format, args, nodeId);
        return error.CompileError;
    }

    pub fn getNodeTokenString(self: *const CompileChunk, node: cy.Node) []const u8 {
        const token = self.tokens[node.start_token];
        return self.src[token.pos()..token.data.end_pos];
    }

    /// An optional debug sym is only included in Debug builds.
    pub fn pushOptionalDebugSym(self: *CompileChunk, nodeId: cy.NodeId) !void {
        if (builtin.mode == .Debug or self.compiler.vm.config.genAllDebugSyms) {
            try self.buf.pushDebugSym(self.buf.ops.items.len, self.id, nodeId, self.curBlock.frameLoc);
        }
    }

    pub fn pushDebugSym(self: *CompileChunk, nodeId: cy.NodeId) !void {
        try self.buf.pushDebugSym(self.buf.ops.items.len, self.id, nodeId, self.curBlock.frameLoc);
    }

    fn pushDebugSymAt(self: *CompileChunk, pc: usize, nodeId: cy.NodeId) !void {
        try self.buf.pushDebugSym(pc, self.id, nodeId, self.curBlock.frameLoc);
    }

    pub fn getModule(self: *CompileChunk) *sema.Module {
        return &self.compiler.sema.modules.items[self.modId];
    }
};

const LocalId = u8;

const GenBlock = struct {
    /// This includes the return info, function params, captured params, and local vars.
    /// Does not include temp locals.
    numLocals: u32,
    frameLoc: cy.NodeId = cy.NullId,
    rFuncSymId: sema.ResolvedFuncSymId = cy.NullId,
    endLocalsPc: u32,

    /// These are used for rvalues and function args.
    /// At the end of the block, the total stack size needed for the function body is known.
    numTempLocals: u8,

    /// Starts at `numLocals`.
    /// Temp locals are allocated from the end of the user locals towards the right.
    firstFreeTempLocal: u8,

    /// Start of the first reserved temp local.
    reservedTempLocalStart: u32,

    /// Whether codegen should create an ending that returns 1 arg.
    /// Otherwise `ret0` is generated.
    requiresEndingRet1: bool,

    fn init() GenBlock {
        return .{
            .numLocals = 0,
            .endLocalsPc = 0,
            .numTempLocals = 0,
            .firstFreeTempLocal = 0,
            .reservedTempLocalStart = 0,
            .requiresEndingRet1 = false,
        };
    }

    fn deinit(self: *GenBlock, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }

    fn getRequiredStackSize(self: *const GenBlock) u8 {
        return @intCast(u8, self.numLocals + self.numTempLocals);
    }
};

const BlockJumpType = enum {
    jumpToEndLocals,
};

const BlockJump = struct {
    jumpT: BlockJumpType,
    pc: u32,

    /// Offset from `pc` to where the jump value should be encoded.
    pcOffset: u16,
};

const SubBlockJumpType = enum {
    /// Each if/else body contains a break at the end to jump out of the if block.
    /// Each match case block jumps to the end of the match block.
    subBlockBreak,
    /// Breaks out of a for loop.
    brk,
    /// Continues a for loop.
    cont,
};

const SubBlockJump = struct {
    jumpT: SubBlockJumpType,
    pc: u32,
};

const ImportTask = struct {
    chunkId: CompileChunkId,
    nodeId: cy.NodeId,
    absSpec: []const u8,
    modId: sema.ModuleId,
    builtin: bool,
};

pub fn initModuleCompat(comptime name: []const u8, comptime initFn: fn (vm: *VMcompiler, mod: *cy.Module) anyerror!void) cy.ModuleLoaderFunc {
    return struct {
        fn initCompat(vm: *cy.UserVM, mod: *cy.Module) bool {
            initFn(&vm.internal().compiler, mod) catch |err| {
                log.debug("Init module `{s}` failed: {}", .{name, err});
                return false;
            };
            return true;
        }
    }.initCompat;
}

pub const CompileConfig = struct {
    skipCodegen: bool = false,
    enableFileModules: bool = false,
};

pub const ValidateConfig = struct {
    enableFileModules: bool = false,
};