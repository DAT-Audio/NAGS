import WindowsInserts

// The VST3 scanner child: module paths in on standard input, descriptions out, one
// module at a time, so a plug-in that crashes on loading takes down only this process. Started
// by `VST3Catalog` with no window; not meant to be run by hand, though it can be:
//   echo C:\path\to\Some.vst3 | nag-vst3-scan
VST3ScannerChild.run()
