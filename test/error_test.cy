-- Copyright (c) 2023 Cyber (See LICENSE)

import t 'test'

err = error(#FileNotFound)
try t.eq(valtag(err), #error)
try t.eq(err, error(#FileNotFound))