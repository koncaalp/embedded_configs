import 'dart:io';

import 'build_exception.dart';

class KeyConfig {
  final List<String>? sources;
  final String outDir;
  final Map? inline;

  KeyConfig._(this.sources, this.outDir, this.inline);

  factory KeyConfig.fromBuildConfig(dynamic config, dynamic env,
      {String outDir = ''}) {
    List<String>? sources;
    Map? inline;
    Uri uri = Uri.parse(config);
    String basePath = uri
        .replace(
            pathSegments: uri.pathSegments.map((segment) {
          return (segment == env) ? "base" : segment;
        }).toList())
        .toString();
    basePath = "./$basePath";

    if (config is String) {
      // Specified just a single file source

      // File('fileName').writeAsStringSync(env);

      if (File(basePath).existsSync()) {
        sources = [basePath, config];
      } else {
        sources = [config];
      }
    } else if (config is Map) {
      // Read the source config
      File('fileName').writeAsStringSync("esle girdm");
      final source = config['source'];

      if (source != null) {
        if (source is String) {
          // Single file source
          sources = [source];
        } else if (source is List) {
          // Multiple file sources
          sources = source.cast<String>().toList();
        } else {
          throw BuildException(
              'Embedded config key source must be a string or list.');
        }
      }

      // Read the inline config
      final _inline = config['inline'];

      if (_inline != null) {
        if (_inline is Map) {
          inline = _inline;
        } else {
          throw BuildException(
              'Embedded config key inline source must be a map.');
        }
      }
    } else {
      throw BuildException(
          'Embedded config key config must be a string or a map.');
    }

    // Ensure at least one source was specified
    if (sources == null && inline == null) {
      throw BuildException(
          'Embedded config key must specify at least one file source or an '
          'inline source.');
    }
    File('fileName').writeAsStringSync("sources: ${sources.toString()}\n",
        mode: FileMode.append);
    return KeyConfig._(sources, outDir, inline);
  }
}
