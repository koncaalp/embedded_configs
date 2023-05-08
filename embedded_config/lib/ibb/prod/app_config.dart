import 'package:embedded_config_annotations/embedded_config_annotations.dart';

// Add the generated file as a part
part './app_config.embedded.dart';

@EmbeddedConfig('app_config')
abstract class AppConfig {
  String get apiUrl;
  String get baseConf;
  String get rBaseConf;
  String get newConfig;
  List get listConfig;

  const AppConfig();
}
