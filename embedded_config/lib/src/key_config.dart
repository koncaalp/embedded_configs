import 'build_exception.dart';

class KeyConfig {
  final List<String>? sources;
  final String outDir;
  final Map? inline;

  KeyConfig._(this.sources, this.outDir, this.inline);

  factory KeyConfig.fromBuildConfig(dynamic config, {String outDir = ''}) {
    List<String>? sources;
    Map? inline;

    if (config is String) {
      // Specified just a single file source
      sources = [config];
    } else if (config is Map) {
      // Read the source config
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

    return KeyConfig._(sources, outDir, inline);
  }
}
