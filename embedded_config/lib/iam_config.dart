import 'package:embedded_config_annotations/embedded_config_annotations.dart';

// Add the generated file as a part
part './iam_config.embedded.dart';

@EmbeddedConfig('iam_config')
abstract class IAmConfig {
  int get build;

  const IAmConfig();
}
