" cyber.vim
if exists("b:current_syntax")
    finish
  endif
  
  " Set the syntax name
  if version < 600
    syntax clear
  endif
  
  syntax case match
  syntax sync minlines=256
  
  if version >= 508 || !exists("did_cyber_syn_inits")
    if version < 508
      let did_cyber_syn_inits = 1
      command -nargs=+ HiLink hi link <args>
    else
      command -nargs=+ HiLink hi def link <args>
    endif
    let did_cyber_hilink = 1
  endif
  
  " Define the keywords
  " Source      : import exort
  " Conditional : if then else and or not 
  " Operator    : and or not is  
  " Handlers    : try catch 
  " Repeat      : for while each 
  " Branch      : break return pass 
  " Statement   : print return as
  " Idenifier   : var static 
  " Func        : func  
  " TypeDef     : object bool, number, int, string, list, map, error, fiber, any, atype 
  " ? coinit coresume coyield capture   typeid
  
  syn keyword cyberSource      import exort
  syn keyword cyberIdentifier  const var coinit coresume coyield
  syn keyword cyberOperator    typeid
  syn keyword cyberConditional if then else and or not is
  syn keyword cyberRepeat      for while each
  syn keyword cyberBranch      break return pass
  syn keyword cyberStatement   print return as
  syn keyword cyberHandler     try catch
  syn keyword cyberFunc        func
  syn keyword cyberModules     core os math test
  syn keyword cyberTypeDef     object bool number int string list map error fiber any atype 
  
  " Define the comment syntax
  "  syn match cyberComment /--.*/ contains=@Spell
  syn match cyberComment "--.*$"
  
  " Define the string syntax
  syn match cyberString /".*"/ contains=cyberEscape
  syn match cyberString /'.*'/ contains=cyberEscape
  syn match cyberEscape /\\./ contained
  
  " Define the variable syntax
  syn match cyberVariable /\v<[a-zA-Z_]\w*>/
  
  " Define the function syntax
  syn keyword cyberFuncKeyword  func contained
  syn region  cyberFuncExp      start=/\w\+\s\==\s\=func\>/ end="\([^)]*\)" contains=cyberFuncEq,cyberFuncKeyword,cyberFuncArg keepend
  syn match   cyberFuncArg      "\(([^()]*)\)" contains=cyberParens,cyberFuncComma contained
  syn match   cyberFuncComma    /,/ contained
  syn match   cyberFuncEq       /=/ contained
  syn region  cyberFuncDef      start="\<func\>" end="\([^)]*\)" contains=cyberFuncKeyword,cyberFuncArg keepend
  
  " Define the constant syntax
  syn keyword cyberConstant var 
  syn keyword cyberModules core os math test
  
  " Define the preprocessor syntax
  syn match cyberPreproc /^#!.*$/ contains=cyberConstant
  
  " Define the statement syntax
  syn match cyberStatement /\v<(print)>/
  syn match cyberStatement /\v<(try|catch|)>/
  
  " Define the operator syntax
  syn match cyberOperator /\v[+=\-*/><!~&|%?^]+/
  
  " Define the number syntax
  syn match cyberNumber /\v<\d+(\.\d+)?>/
  
  " Highlight the function calls
  syn region cyberFunctionCall start="\w\+\s*(" end=")" contains=cyberStatement, cyberOperator, cyberString, cyberVariable, cyberNumber
  
  " Highlight the imported modules
  syn region cyberImport start="import\s\+" end="\s\+'" contains=cyberConstant, cyberString
  
  syn match cyberEmptyObject /{}/
  syn match cyberBoolean /\btrue\b\|\bfalse\b/
  
  " Highlight file and directory names
  syn match cyberFileName /('\w+'\/\w+)+/ contained
  syn match cyberDirName /{\w+\.?\w*}/ contained
  
  " Highlight string interpolation
  syn region cyberStrInterp start=/{/ end=/}/ contains=cyberString, cyberVariable, cyberFileName, cyberDirName, cyberFunctionName, cyberObjectField
  
  " Highlight the if statement
  syn match cyberConditional /\v^(\s*)?(if|then|else|and|or|not)(\s*)?/
  
  syntax match cyberBraces "[{}\[\]]"
  syntax match cyberParens "[()]"
  
  " Highlight the exit statement
  syn match cyberExit /\v(exit)(\s*)?(\d+)?/
  
  syn cluster cyberAll contains=cyberSource,cyberImport,cyberIdentifier,cyberOperator,cyberConditional,cyberRepeat,cyberBranch,cyberStatement,cyberHandler,cyberFunc,cyberModules,cyberTypeDef,cyberComment,cyberString,cyberVariable,cyberFuncKeyword,cyberFuncExp,cyberFuncArg,cyberFuncComma,cyberFuncEq,cyberFuncDef,cyberConstant,cyberModules,cyberPreproc,cyberStatement,cyberOperator,cyberNumber,cyberFunctionCall,cyberImport,cyberEmptyObject,cyberBoolean,cyberFileName,cyberDirName,cyberStrInterp,cyberConditional,cyberBraces,cyberParens,cyberExit
  
  
  " Set the default highlighting
  if exists("did_cyber_hilink")
    HiLink cyberSource      Special
    HiLink cyberImport      Include
    
    HiLink cyberKeywords    Keyword
    HiLink cyberEscape      SpecialChar
    
    HiLink cyberSource      Special
    HiLink cyberIdentifier  Identifier 
    HiLink cyberOperator    Operator
    HiLink cyberConditional Conditional
    HiLink cyberRepeat      Repeat
    HiLink cyberBranch      Conditional
    HiLink cyberStatement   Statement
    HiLink cyberHandler     Special
    HiLink cyberFunc        Function 
    HiLink cyberModules     Special
    HiLink cyberTypeDef     Type    
  
    HiLink cyberComment     Comment
    HiLink cyberString      String
    HiLink cyberVariable    Identifier
    
    HiLink cyberFuncKeyword Function 
    HiLink cyberFuncExp     Title
    HiLink cyberFuncArg     Special    
    HiLink cyberFuncComma   Operator   
    HiLink cyberFuncEq      Operator
    HiLink cyberFuncDef     PreProc   
  
    HiLink cyberConstant    Constant
    HiLink cyberModules     Special
    HiLink cyberPreproc     PreProc
    HiLink cyberStatement   Statement
    HiLink cyberOperator    Operator
    HiLink cyberNumber      Number
  
    HiLink cyberEmptyObject Special
    HiLink cyberBoolean     Boolean
  
    HiLink cyberFileName    String
    HiLink cyberDirName     String
  
    HiLink cyberStrInterp   String
    HiLink cyberConditional Conditional
  
    HiLink cyberBraces      Function
    HiLink cyberParens      Operator
  
    HiLink cyberExit Special
  
    delcommand HiLink
    if exists("did_cyber_syn_inits")
      unlet did_cyber_syn_inits
    endif
    unlet did_cyber_hilink
  endif
  
  let b:current_syntax = "cyber"
  