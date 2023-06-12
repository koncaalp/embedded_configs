import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart';
import 'package:embedded_config_annotations/embedded_config_annotations.dart';
import 'package:glob/glob.dart';
import 'package:source_gen/source_gen.dart' as source_gen;
import 'package:dart_style/dart_style.dart';

import 'build_exception.dart';
import 'environment_provider.dart';
import 'key_config.dart';
import 'package:file/local.dart';
import 'package:path/path.dart' as path;

const _classAnnotationTypeChecker =
    source_gen.TypeChecker.fromRuntime(EmbeddedConfig);
const _getterNameAnnotationTypeChecker =
    source_gen.TypeChecker.fromRuntime(EmbeddedPropertyName);
const _stringTypeChecker = source_gen.TypeChecker.fromRuntime(String);
const _listTypeChecker = source_gen.TypeChecker.fromRuntime(List);
const _mapTypeChecker = source_gen.TypeChecker.fromRuntime(Map);
const _numTypeChecker = source_gen.TypeChecker.fromRuntime(num);
const _boolTypeChecker = source_gen.TypeChecker.fromRuntime(bool);

class _AnnotatedClass {
  final ClassElement element;
  final EmbeddedConfig annotation;
  final Map<PropertyAccessorElement, String> annotatedGetters;

  _AnnotatedClass(this.element, this.annotation, this.annotatedGetters);
}

List<String> searchDirectory(Directory directory, String targetFileName) {
  List<String> paths = [];
  var contents = directory.listSync(recursive: false, followLinks: false);
  bool foundTarget = false;
  String directoryPath;

  for (FileSystemEntity entity in contents) {
    if (entity is File && entity.path.endsWith(targetFileName)) {
      directoryPath = path.dirname(entity.path);
      print("Found target file: $directoryPath");
      paths.add(directoryPath);
      foundTarget = true;
    } else if (entity is Directory) {
      if (!foundTarget) {
        List<String> pathsFromRecursion =
            searchDirectory(entity, targetFileName);
        paths.addAll(pathsFromRecursion);
      } else {
        foundTarget = false;
      }
    }
  }
  return paths;
}

List<String> getEnvs() {
  List<String> envs = [];
  String directoryPath = './assets';
  String targetFilename = 'flavor.json';
  Uri uri;
  String flavor;
  String env;
  List<String> pathSegments;

  final directory = Directory(directoryPath);
  List<String> paths = searchDirectory(directory, targetFilename);
  print(paths.toString());
  for (String p in paths) {
    uri = Uri.parse(p);
    pathSegments = uri.pathSegments;
    flavor = pathSegments[1];
    env = pathSegments[2];
    envs.add(env);
  }
  return envs;
}

class ConfigGenerator extends source_gen.Generator {
  final List<Map<String, KeyConfig>> _keysList;
  final EnvironmentProvider _environmentProvider;
  final _formatter = DartFormatter();

  ConfigGenerator(Map<String, dynamic> config,
      {EnvironmentProvider environmentProvider =
          const PlatformEnvironmentProvider()})
      // Parse key configs
      : _keysList = _generateKeysList(config),
        _environmentProvider = environmentProvider;

  static List<Map<String, KeyConfig>> _generateKeysList(
      Map<String, dynamic> config) {
    final glob = Glob(config['configs']);
    final envs = getEnvs();
    final matchedList = glob.listFileSystemSync(const LocalFileSystem());
    final keysList = matchedList.map((e) {
      String outPath = e.parent.path;

      for (String env in envs) {
        if (outPath.contains('/$env/')) {
          outPath = outPath.replaceAll('/$env/', '/$env/embedded/');
          break;
        }
      }

      outPath = outPath.replaceAll('assets', config['out_dir']);
      File('debug.txt').writeAsStringSync('generateKeysList: $outPath',
          mode: FileMode.append);

      return {
        basenameWithoutExtension(e.path):
            KeyConfig.fromBuildConfig(e.path, outDir: outPath)
      };
    }).toList();

    File('debug.txt')
        .writeAsStringSync('envs: ${envs.toString()}', mode: FileMode.append);

    return keysList;
  }

  /// With this quick & dirty update, multiple config files are supported now. kind of flavor support.
  /// configs should be placed at the build.yaml respecting to glob pattern.
  /// ie.
  ///      options:
  ///        app_configs: 'assets/**app_config.json'
  ///
  /// Instead of implementing our own generator, it might be preferable to override current [ConfigGenerator].
  /// With this update, it's no longer compatible with the further updates of upstream repo.
  /// And won't take many of the advantages of build_runner anymore.
  /// If current changes met our needs, we can think about to refactor (or to create a new generator with the same capabilities) it.
  /// This repo is no longer a valid
  @override
  FutureOr<String?> generate(
      source_gen.LibraryReader library, BuildStep buildStep) async {
    await Future.forEach(_keysList, (Map<String, dynamic> keys) async {
      final configName = basenameWithoutExtension(buildStep.inputId.path);
      final keyConfig = keys[configName] as KeyConfig?;

      if (keyConfig != null) {
        try {
          final content = await _generate(library, buildStep, keys);
          if (content != null) {
            final String outDir = keyConfig.outDir;
            final fileName = '$outDir/$configName.embedded.dart';
            if (!File(fileName).existsSync()) {
              File(fileName).createSync(recursive: true);
            }
            File(fileName)
                .writeAsStringSync(_formatContent(content, configName));
          }
        } on Exception catch (e) {
          print("Can't generate $configName for ${keyConfig.outDir} -  $e");
        }
      } else {
        // just continue;
      }
    });

    return null;
  }

  FutureOr<String?> _generate(source_gen.LibraryReader library,
      BuildStep buildStep, Map<String, dynamic> keys) async {
    // Get annotated classes
    final sourceClasses = <_AnnotatedClass>[];
    final annotatedElements =
        library.annotatedWith(_classAnnotationTypeChecker);

    for (final annotatedElement in annotatedElements) {
      final classElement = annotatedElement.element;

      if (classElement is! ClassElement ||
          !classElement.isAbstract ||
          classElement.isEnum) {
        throw BuildException(
            'Only abstract classes may be annotated with @EmbeddedConfig!',
            classElement);
      }

      // Get annotated getters
      final annotatedGetterNames = <PropertyAccessorElement, String>{};

      for (final accessor in classElement.accessors) {
        final annotation =
            _getterNameAnnotationTypeChecker.firstAnnotationOf(accessor);

        if (annotation != null) {
          final reader = source_gen.ConstantReader(annotation);

          annotatedGetterNames[accessor] = reader.read('name').stringValue;
        }
      }

      sourceClasses.add(_AnnotatedClass(
          classElement,
          _reconstructClassAnnotation(annotatedElement.annotation),
          annotatedGetterNames));
    }

    // Build classes
    final classes = <Class>[];
    final generatedClasses = <String>{};

    for (final annotatedClass in sourceClasses) {
      // Resolve real config values
      final config = await _resolveConfig(
          buildStep, annotatedClass.element, annotatedClass.annotation, keys);

      // Generate class
      final $class = _generateClass(
          annotatedClass.element,
          annotatedClass.annotatedGetters,
          config,
          sourceClasses,
          generatedClasses);

      if ($class != null) {
        classes.add($class);
      }
    }

    // Check if any classes were generated
    if (classes.isEmpty) {
      // Don't create a file if nothing was generated
      return null;
    }

    // Build library
    final libraryAst = Library((l) => l..body.addAll(classes));

    // Emit source
    final emitter = DartEmitter(allocator: Allocator.simplePrefixing());

    return libraryAst.accept(emitter).toString();
  }

  /// Reconstructs an [EmbeddedConfig] annotation from a
  /// [source_gen.ConstantReader] of one.
  EmbeddedConfig _reconstructClassAnnotation(source_gen.ConstantReader reader) {
    String key;
    List<String>? path;

    final keyReader = reader.read('key');
    key = keyReader.stringValue;

    final pathReader = reader.read('path');
    if (!pathReader.isNull) {
      path = pathReader.listValue.map((v) => v.toStringValue()!).toList();
    }

    File('debug').writeAsStringSync(
        'reconstructClassAnnotation: ${path.toString()}',
        mode: FileMode.append);

    return EmbeddedConfig(key, path: path);
  }

  /// Resolves the config values for the given embedded config [annotation].
  Future<Map<String, dynamic>> _resolveConfig(
      BuildStep buildStep,
      ClassElement classElement,
      EmbeddedConfig annotation,
      Map<String, dynamic> keys) async {
    // Get the key config
    final KeyConfig? keyConfig = keys[annotation.key];

    if (keyConfig == null) {
      throw BuildException(
          'No embedded config defined for key: ${annotation.key}',
          classElement);
    }

    var config = <String, dynamic>{};

    // Apply file sources
    if (keyConfig.sources != null) {
      for (final filePath in keyConfig.sources!) {
        // Read file
        final assetId = AssetId(buildStep.inputId.package, filePath);
        final assetContents = await buildStep.readAsString(assetId);

        Map<String, dynamic> fileConfig;

        if (filePath.trimRight().endsWith('.json')) {
          fileConfig = json.decode(assetContents);
        } else {
          throw BuildException(
              'Embedded config file sources must be JSON documents.',
              classElement);
        }

        // Merge file into config
        _mergeMaps(config, fileConfig);
      }
    }

    // Apply inline source
    if (keyConfig.inline != null) {
      _mergeMaps(config, keyConfig.inline!);
    }

    // Follow path if specified
    if (annotation.path != null) {
      for (final key in annotation.path!) {
        if (config.containsKey(key)) {
          if (config[key] == null) {
            return {};
          } else {
            config = config[key];
          }
        } else {
          throw BuildException(
              "Could not follow path '${annotation.path}' for config "
              '${annotation.key}.',
              classElement);
        }
      }
    }

    return config;
  }

  /// Merges the [top] map on top of the [base] map, overwriting values at the
  /// lowest level possible.
  void _mergeMaps(Map base, Map top) {
    top.forEach((k, v) {
      final baseValue = base[k];

      if (baseValue != null && baseValue is Map && v is Map) {
        _mergeMaps(baseValue, v);
      } else {
        base[k] = v;
      }
    });
  }

  /// Generates a class for the given [$class] element using the given [config].
  Class? _generateClass(
      ClassElement $class,
      Map<PropertyAccessorElement, String> getterNames,
      Map<String, dynamic> config,
      List<_AnnotatedClass> sourceClasses,
      Set<String> generatedClasses) {
    if (generatedClasses.contains($class.name)) {
      // This class has already been generated
      return null;
    }

    generatedClasses.add($class.name);

    // Generate field overrides for each non-static abstract getter
    final fields = <Field>[];

    final getters = $class.accessors.where((accessor) =>
        accessor.isGetter && !accessor.isStatic && accessor.isAbstract);

    for (final getter in getters) {
      try {
        fields.add(_generateOverrideForGetter(
            getter, config, sourceClasses, getterNames[getter]));
      } on BuildException catch (ex) {
        if (ex.element == null) {
          // Attach getter element to exception
          throw BuildException(ex.message, getter);
        } else {
          rethrow;
        }
      }
    }

    // Ensure class declares a constant default constructor
    final constructor = $class.unnamedConstructor;
    if (constructor == null || !constructor.isConst) {
      throw BuildException(
          'Embedded config classes must declare a const default constructor.',
          $class);
    }

    // Build class
    return Class((c) => c
      ..name = _generatedClassNameOf($class.name)
      ..extend = refer($class.name)
      ..fields.addAll(fields)
      ..constructors.add(Constructor((t) => t..constant = true)));
  }

  /// Generates a field which overrides the given [getter].
  ///
  /// The field contains the embedded config value for the
  /// [getter] retrieved from the [config].
  Field _generateOverrideForGetter(
      PropertyAccessorElement getter,
      Map<String, dynamic> config,
      List<_AnnotatedClass> sourceClasses,
      String? customKey) {
    final returnType = getter.returnType;

    // Determine key
    final String key;

    if (customKey == null) {
      key = getter.isPrivate ? getter.name.substring(1) : getter.name;
    } else {
      key = customKey;
    }

    // Ensure non-null value provided for non-null field
    if (returnType.nullabilitySuffix == NullabilitySuffix.none &&
        !returnType.isDynamic &&
        config[key] == null) {
      throw BuildException(
          'Must provide a non-null config value for a non-nullable config property.');
    }

    // Handle type
    if (_stringTypeChecker.isExactlyType(returnType)) {
      // String
      final value = _getString(config, key);

      return Field((f) => f
        ..annotations.add(refer('override'))
        ..modifier = FieldModifier.final$
        ..name = getter.name
        ..assignment = _codeLiteral(value));
    } else if (_listTypeChecker.isAssignableFromType(returnType)) {
      // List
      var forceStrings = false;

      if (returnType is ParameterizedType) {
        // Force all values to strings if this is a List<String>
        forceStrings = returnType.typeArguments.isNotEmpty &&
            _stringTypeChecker.isExactlyType(returnType.typeArguments.first);
      }

      final value = _getList(config, key, forceStrings: forceStrings);

      return Field((f) => f
        ..annotations.add(refer('override'))
        ..modifier = FieldModifier.final$
        ..name = getter.name
        ..assignment = _codeLiteral(value));
    } else if (_mapTypeChecker.isAssignableFromType(returnType)) {
      // Map
      var forceStrings = false;

      if (returnType is ParameterizedType) {
        // Force all values to strings if this is a Map<T, String>
        forceStrings = returnType.typeArguments.length > 1 &&
            _stringTypeChecker.isExactlyType(returnType.typeArguments[1]);
      }

      final value = _getMap(config, key, forceStrings: forceStrings);

      return Field((f) => f
        ..annotations.add(refer('override'))
        ..modifier = FieldModifier.final$
        ..name = getter.name
        ..assignment = _codeLiteral(value));
    } else if (_numTypeChecker.isAssignableFromType(returnType) ||
        _boolTypeChecker.isAssignableFromType(returnType) ||
        returnType.isDynamic) {
      // Num, bool, dynamic, num? (note: num? will be dynamic)
      final value = _getLiteral(config, key);

      return Field((f) => f
        ..annotations.add(refer('override'))
        ..modifier = FieldModifier.final$
        ..name = getter.name
        ..assignment = _codeLiteral(value));
    } else if (returnType.element is ClassElement) {
      // Class
      final innerClass = returnType.element as ClassElement;

      if (returnType.element!.library != getter.library) {
        throw BuildException(
            'Cannot reference a class from a different library as '
            'a config property.');
      }

      if (!sourceClasses.any((c) => c.element == innerClass)) {
        throw BuildException(
            'Cannot reference a non embedded config class as a config '
            'property.');
      }

      // Add field
      return Field((f) => f
        ..annotations.add(refer('override'))
        ..modifier = FieldModifier.final$
        ..name = getter.name
        ..assignment = config[key] == null
            ? _codeLiteral(null)
            : _codeClassInstantiation(_generatedClassNameOf(innerClass.name)));
    } else {
      // Any
      throw BuildException('Type $returnType is not supported.');
    }
  }

  /// If the given [string] starts with `$`, then the value of
  /// the environment variable with the name specified by the remaining
  /// characters in [string] after the `$` will be returned.
  ///
  /// If [string] starts with `\$` then the `$` will be treated as
  /// an escaped character (environment variables will not be queried)
  /// and the first `\` will be removed. This also means that for every
  /// `\` starting character after the first, one will always be removed
  /// to account for the escaping (ex. `\\$` turns into `\$`).
  String? _checkEnvironmentVariable(String string) {
    if (string.startsWith(RegExp(r'^\\+\$'))) {
      return string.substring(1);
    } else if (string.startsWith(r'$')) {
      return _environmentProvider.environment[string.substring(1)];
    } else {
      return string;
    }
  }

  String? _getLiteral(Map<String, dynamic> map, String key) {
    final dynamic value = map[key];

    if (value == null) return null;

    return _makeLiteral(value);
  }

  String? _getString(Map<String, dynamic> map, String key) {
    final dynamic value = map[key];

    if (value == null) return null;

    if (value is String) {
      return _makeStringLiteral(_checkEnvironmentVariable(value));
    } else {
      return _makeStringLiteral(value.toString());
    }
  }

  String? _getList(Map<String, dynamic> map, String key,
      {bool forceStrings = false}) {
    final dynamic value = map[key];

    if (value == null) return null;

    if (value is List) {
      return _makeListLiteral(value, forceStrings: forceStrings);
    } else {
      throw BuildException("Config value '$key' must be a list.");
    }
  }

  String? _getMap(Map<String, dynamic> map, String key,
      {bool forceStrings = false}) {
    final dynamic value = map[key];

    if (value == null) return null;

    if (value is Map) {
      return _makeMapLiteral(value, forceStrings: forceStrings);
    } else {
      throw BuildException("Config value '$key' must be a map.");
    }
  }

  String _makeLiteral(dynamic value) {
    if (value is String) {
      return _makeStringLiteral(_checkEnvironmentVariable(value));
    } else if (value is bool) {
      return _makeBoolLiteral(value);
    } else if (value is List) {
      return _makeListLiteral(value);
    } else if (value is Map) {
      return _makeMapLiteral(value);
    } else {
      return value.toString();
    }
  }

  String _makeBoolLiteral(bool value) {
    return value ? 'true' : 'false';
  }

  String _makeStringLiteral(String? value) {
    if (value != null) {
      value = value
          .replaceAll('\\', '\\\\')
          .replaceAll("'", "\\'")
          .replaceAll(r'$', '\\\$');
    }

    return "'$value'";
  }

  String _makeListLiteral(List value, {bool forceStrings = false}) {
    final buffer = StringBuffer();
    buffer.write('const [');

    for (var i = 0; i < value.length; i++) {
      if (i > 0) {
        buffer.write(',');
      }

      final element = value[i];

      if (element is String) {
        buffer.write(_makeStringLiteral(_checkEnvironmentVariable(element)));
      } else {
        if (forceStrings) {
          buffer.write(_makeStringLiteral(element.toString()));
        } else {
          buffer.write(_makeLiteral(element));
        }
      }
    }

    buffer.write(']');

    return buffer.toString();
  }

  String _makeMapLiteral(Map value, {bool forceStrings = false}) {
    final buffer = StringBuffer();
    buffer.write('const {');

    var first = true;
    for (final entry in value.entries) {
      if (!first) {
        buffer.write(',');
      }

      buffer.write(_makeStringLiteral(entry.key.toString()));
      buffer.write(': ');

      final value = entry.value;

      if (value is String) {
        buffer.write(_makeStringLiteral(_checkEnvironmentVariable(value)));
      } else {
        if (forceStrings && value is! List && value is! Map) {
          buffer.write(_makeStringLiteral(value.toString()));
        } else {
          buffer.write(_makeLiteral(value));
        }
      }

      first = false;
    }

    buffer.write('}');

    return buffer.toString();
  }

  Code _codeLiteral(String? value) {
    if (value == null) return const Code('null');

    return Code(value);
  }

  Code _codeClassInstantiation(String className) {
    return Code('const $className()');
  }

  String _generatedClassNameOf(String className) {
    return '_\$${className}Embedded';
  }

  String _formatContent(String content, String partOf) {
    final formattedContent = '''
      // GENERATED CODE - DO NOT MODIFY BY HAND
      
      part of $partOf;
      
      // **************************************************************************
      // ConfigGenerator
      // **************************************************************************
      
      $content
      ''';

    return _formatter.format(formattedContent);
  }
}
