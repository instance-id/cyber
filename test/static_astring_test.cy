-- Copyright (c) 2023 Cyber (See LICENSE)

import t 'test'

-- Single quote literal.
str = 'abc'
try t.eq(str, 'abc')

-- Const string multi-line double quote literal.
str = "abc
abc"
try t.eq(str, 'abc\nabc')

-- Const string multi-line triple quote literal.
str = '''abc
abc'''
try t.eq(str, 'abc\nabc')

str = 'abcxyz'

-- index operator
try t.eq(str[-1], 'z')
try t.eq(str[0], 'a')
try t.eq(str[3], 'x')
try t.eq(str[5], 'z')
try t.eq(str[6], error(#OutOfBounds))

-- slice operator
try t.eq(str[0..], 'abcxyz')
try t.eq(str[3..], 'xyz')
try t.eq(str[5..], 'z')
try t.eq(str[-1..], 'z')
try t.eq(str[6..], '')
try t.eq(str[7..], error(#OutOfBounds))
try t.eq(str[-10..], error(#OutOfBounds))
try t.eq(str[..0], '')
try t.eq(str[..3], 'abc')
try t.eq(str[..5], 'abcxy')
try t.eq(str[..-1], 'abcxy')
try t.eq(str[..6], 'abcxyz')
try t.eq(str[..7], error(#OutOfBounds))
try t.eq(str[0..0], '')
try t.eq(str[0..1], 'a')
try t.eq(str[3..6], 'xyz')
try t.eq(str[5..6], 'z')
try t.eq(str[6..6], '')
try t.eq(str[6..7], error(#OutOfBounds))
try t.eq(str[3..1], error(#OutOfBounds))

-- charAt()
try t.eq(str.charAt(-1), error(#OutOfBounds))
try t.eq(str.charAt(0), 'a')
try t.eq(str.charAt(3), 'x')
try t.eq(str.charAt(5), 'z')
try t.eq(str.charAt(6), error(#OutOfBounds))

-- codeAt()
try t.eq(str.codeAt(-1), error(#OutOfBounds))
try t.eq(str.codeAt(0), 97)
try t.eq(str.codeAt(3), 120)
try t.eq(str.codeAt(5), 122)
try t.eq(str.codeAt(6), error(#OutOfBounds))

-- concat()
try t.eq(str.concat('123'), 'abcxyz123')
try t.eq(str.concat('123').isAscii(), true)
try t.eq(str.concat('🦊').isAscii(), false)

-- endsWith()
try t.eq(str.endsWith('xyz'), true)
try t.eq(str.endsWith('xy'), false)

-- index()
try t.eq(str.index('bc'), 1)
try t.eq(str.index('bd'), none)
try t.eq(str.index('ab'), 0)

-- index() simd 32-byte fixed. Need 'aaa' padding for needle.len = 3 to trigger simd fixed.
try t.eq('abcdefghijklmnopqrstuvwxyz123456aaa'.index('bc'), 1)
try t.eq('abcdefghijklmnopqrstuvwxyz123456aaa'.index('bd'), none)
try t.eq('abcdefghijklmnopqrstuvwxyz123456aaa'.index('ab'), 0)
try t.eq('abcdefghijklmnopqrstuvwxyz123456aaa'.index('456'), 29)
try t.eq('abcdefghijklmnopqrstuvwxyz123456aaa'.index('56'), 30)
try t.eq('abcdefghijklmnopqrstuvwxyz123456aaa'.index('6'), 31)

-- index() simd 32-byte remain.
try t.eq('abcdefghijklmnopqrstuvwxyz123456789'.index('7'), 32)
try t.eq('abcdefghijklmnopqrstuvwxyz123456789'.index('78'), 32)
try t.eq('abcdefghijklmnopqrstuvwxyz123456789'.index('789'), 32)
try t.eq('abcdefghijklmnopqrstuvwxyz123456789'.index('780'), none)
try t.eq('abcdefghijklmnopqrstuvwxyz123456789'.index('mnopqrstuv'), 12)
try t.eq('abcdefghijklmnopqrstuvwxyz123456789'.index('mnopqrstuw'), none)

-- indexChar()
try t.eq(str.indexChar('a'), 0)
try t.eq(str.indexChar('b'), 1)
try t.eq(str.indexChar('c'), 2)
try t.eq(str.indexChar('d'), none)

-- indexChar() simd
lstr = 'aaaaaaaaaaaaaaaamaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaza'
try t.eq(lstr.indexChar('a'), 0)
try t.eq(lstr.indexChar('m'), 16)
try t.eq(lstr.indexChar('z'), 68)

-- indexCharSet()
try t.eq(str.indexCharSet('a'), 0)
try t.eq(str.indexCharSet('ae'), 0)
try t.eq(str.indexCharSet('ea'), 0)
try t.eq(str.indexCharSet('fe'), none)
try t.eq(str.indexCharSet('cd'), 2)
try t.eq(str.indexCharSet('dc'), 2)
try t.eq(str.indexCharSet('cdi'), 2)

-- indexCharSet() simd 32-byte fixed
try t.eq('abcdefghijklmnopqrstuvwxyz123456'.indexCharSet('a'), 0)
try t.eq('abcdefghijklmnopqrstuvwxyz123456'.indexCharSet('m'), 12)
try t.eq('abcdefghijklmnopqrstuvwxyz123456'.indexCharSet('6'), 31)
try t.eq('abcdefghijklmnopqrstuvwxyz123456'.indexCharSet('6m'), 12)
try t.eq('abcdefghijklmnopqrstuvwxyz123456'.indexCharSet('0'), none)
try t.eq('abcdefghijklmnopqrstuvwxyz123456'.indexCharSet('07'), none)
try t.eq('abcdefghijklmnopqrstuvwxyz123456'.indexCharSet('07m'), 12)

-- indexCharSet() simd 32-byte remain
try t.eq('abcdefghijklmnopqrstuvwxyz123456789'.indexCharSet('7'), 32)
try t.eq('abcdefghijklmnopqrstuvwxyz123456789'.indexCharSet('8'), 33)
try t.eq('abcdefghijklmnopqrstuvwxyz123456789'.indexCharSet('9'), 34)
try t.eq('abcdefghijklmnopqrstuvwxyz123456789'.indexCharSet('98'), 33)
try t.eq('abcdefghijklmnopqrstuvwxyz123456789'.indexCharSet('0'), none)
try t.eq('abcdefghijklmnopqrstuvwxyz123456789'.indexCharSet('08'), 33)

-- indexCode()
try t.eq(str.indexCode(97), 0)
try t.eq(str.indexCode(98), 1)
try t.eq(str.indexCode(99), 2)
try t.eq(str.indexCode(100), none)

-- insert()
try t.eq(str.insert(-1, 'foo'), error(#OutOfBounds))
try t.eq(str.insert(0, 'foo'), 'fooabcxyz')
try t.eq(str.insert(0, 'foo').isAscii(), true)
try t.eq(str.insert(3, 'foo🦊'), 'abcfoo🦊xyz')
try t.eq(str.insert(3, 'foo🦊').isAscii(), false)
try t.eq(str.insert(5, 'foo'), 'abcxyfooz')
try t.eq(str.insert(6, 'foo'), 'abcxyzfoo')
try t.eq(str.insert(7, 'foo'), error(#OutOfBounds))

-- isAscii()
try t.eq(str.isAscii(), true)

-- len()
try t.eq(str.len(), 6)

-- less()
try t.eq(str.less('ac'), true)
try t.eq(str.less('aa'), false)

-- lower()
try t.eq('ABC'.lower(), 'abc')

-- repeat()
try t.eq(str.repeat(-1), error(#InvalidArgument))
try t.eq(str.repeat(0), '')
try t.eq(str.repeat(0).isAscii(), true)
try t.eq(str.repeat(1), 'abcxyz')
try t.eq(str.repeat(1).isAscii(), true)
try t.eq(str.repeat(2), 'abcxyzabcxyz')
try t.eq(str.repeat(2).isAscii(), true)
try t.eq('abc'.repeat(3), 'abcabcabc')
try t.eq('abc'.repeat(4), 'abcabcabcabc')
try t.eq('abc'.repeat(5), 'abcabcabcabcabc')

-- replace()
try t.eq(str.replace('abc', 'foo'), 'fooxyz')
try t.eq(str.replace('bc', 'foo'), 'afooxyz')
try t.eq(str.replace('bc', 'foo🦊'), 'afoo🦊xyz')
try t.eq(str.replace('bc', 'foo🦊').isAscii(), false)
try t.eq(str.replace('xy', 'foo'), 'abcfooz')
try t.eq(str.replace('xyz', 'foo'), 'abcfoo')
try t.eq(str.replace('abcd', 'foo'), 'abcxyz')

-- startsWith()
try t.eq(str.startsWith('abc'), true)
try t.eq(str.startsWith('bc'), false)

-- upper()
try t.eq(str.upper(), 'ABCXYZ')