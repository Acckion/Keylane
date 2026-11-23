# Licensing and third-party notices

Keylane's original code is distributed under the GNU General Public License,
version 3 or (at your option) any later version (SPDX: GPL-3.0-or-later).
See [LICENSE](LICENSE) for the complete license, including its warranty disclaimer.
This statement does not replace third-party licenses or grant rights to third-party
trademarks, private source code, or proprietary distribution artifacts.

## Included data and test fixtures

- Emoji and Unicode data: [Unicode License V3](Resources/Unicode-LICENSE.txt).
  The packaged app retains this notice alongside the data.
- Raycast extensions test fixtures: [MIT notice](Tests/ExtensionPrototype/LinuxGuest/RAYCAST-EXTENSIONS-LICENSE).
- date-fns test fixtures: [MIT notice](Tests/ExtensionPrototype/LinuxGuest/DATE-FNS-LICENSE).
- UUID suite test fixtures and dependencies: [original notices](Tests/ExtensionPrototype/LinuxGuest/UUID-SUITE-THIRD-PARTY-NOTICES), including MIT and Apache-2.0 terms.

- Restricted-runtime M0 tests download React 19.0.0 and esbuild 0.25.5 from
  the official npm registry with pinned integrity values. Both use the MIT license;
  see [React's original license](https://github.com/facebook/react/blob/v19.0.0/LICENSE)
  and [esbuild's original license](https://github.com/evanw/esbuild/blob/v0.25.5/LICENSE.md).
  React's packaged LICENSE remains alongside its temporary test copy. These tools,
  libraries, generated bundles and test helpers are not included in Keylane.app.

These original notices must be retained when redistributing the corresponding
materials. Test fixtures are not included by the app packaging script.

## References and system components

The README records design inspiration and references to SuperCMD V1 and Raycast.
A reference is not a grant of rights to their code, assets, brands, or binaries.
Any future reuse must be checked against the exact source version's license and
retain the required notices. Apple frameworks and the system SQLite library
remain subject to their respective terms; the project license does not relicense them.

## Window management

The Dock gesture encoding in `WindowSpaceGesture.swift` is adapted from
[iss](https://github.com/joshuarli/iss), under the following terms:

```text
Copyright (c) 2026 joshuarli

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY
AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL,
DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING
FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
```

## Existing releases

This change applies to the source revision containing the license migration and
subsequent covered revisions. Previously published tags, release assets, and their
bundled license files are not rewritten by this change.

## Yams 6.2.2

YAML parsing uses [Yams](https://github.com/jpsim/Yams), distributed under the MIT license.

```text
The MIT License (MIT)

Copyright (c) 2016 JP Simard.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### libyaml (bundled by Yams)

```text
Copyright (c) 2017-2020 Ingy döt Net
Copyright (c) 2006-2016 Kirill Simonov

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

```
