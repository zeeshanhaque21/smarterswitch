/// Per-category Dart MethodChannel wrappers used to live here. As each
/// category grew a full read/write surface, its wrapper moved to its own
/// `<category>_reader.dart` file. This file remains as a placeholder so
/// existing imports (none of which referenced its contents directly) keep
/// resolving — and so future shared helpers across the wrappers have a
/// natural home.
library;
