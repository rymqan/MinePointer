# Third-party notices

MinePointer includes the third-party software listed below. Each part keeps its own license.

## AirPointer

- Location: this repository is a fork of AirPointer with its full history; AirPointer's files are `Sources/AirPointer`, `Sources/ClosedCaseMotion`, `Sources/ClosedCaseRestore`, `Assets/`, `Docs/`, `Scripts/`, `Tests/` and `build.sh`.
- Source: https://github.com/oscarcreatess/airpointer, commit `5dd3a417e4e7b08f4ad64368a56e600f118d0cb3`.
- Modifications: `README.md` is replaced by MinePointer's README (AirPointer's is upstream), `LICENSE` adds MinePointer's copyright line, and `.gitignore` adds MinePointer's entries. AirPointer's code is unmodified.
- What MinePointer uses: `build-minepointer.sh` compiles `Sources/ClosedCaseMotion/CaseSustainedRenewal.m`, `Sources/ClosedCaseRestore/ClosedCaseRestore.swift` and `Sources/AirPointer/Session/ClosedCaseAirPods.swift` into the app. `Sources/MinePointer/CaseSession.swift` contains three functions copied from `Sources/AirPointer/Session/ClosedCaseSession.swift`; each is marked in the code.
- License: MIT.

```
MIT License

Copyright (c) 2026 Oscar Nicholas

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

### Earlier AirPointer by Andy Gao

`oscarcreatess/airpointer` shares most of its code with the earlier https://github.com/musubipapi/airpointer by Andy Gao (first commit 2026-11-05), although the two repositories have no common git history. `ClosedCaseRestore.swift`, for example, is identical in both. Andy Gao's copyright notice is therefore kept here as well.

```
MIT License

Copyright (c) 2026 Andy Gao

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

### AirPointer assets

The MIT license above does not cover `Assets/`. It contains Apple's AirPods Pro 3 AR model, renders of it, and sounds that use parts from cuelume; see `Assets/LICENSE.md`. MinePointer does not build any of these assets into its app; they are in this repository only because it keeps AirPointer's tree unchanged.
