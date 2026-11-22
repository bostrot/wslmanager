import 'service_recipe.dart';

/// The curated set of one-click services. Kept deliberately small and real:
/// each entry is a service people actually run locally for development, on
/// its official image, with fixed dev credentials.
class RecipeCatalog {
  static const List<ServiceRecipe> recipes = [
    // ----- Storage -------------------------------------------------------
    ServiceRecipe(
      id: 'minio',
      name: 'MinIO (S3)',
      category: RecipeCategory.storage,
      description: 'S3-compatible object storage with a web console.',
      image: 'minio/minio:latest',
      containerName: 'wslm-minio',
      port: 9001,
      dashboardPath: '/',
      credentials: 'minioadmin / minioadmin',
      env: {
        'MINIO_ROOT_USER': 'minioadmin',
        'MINIO_ROOT_PASSWORD': 'minioadmin',
      },
      // The API is on 9000, the console on 9001; both are published.
      extraArgs: ['-p', '9000:9000'],
      command: 'server /data --console-address ":9001"',
    ),

    // ----- Databases -----------------------------------------------------
    ServiceRecipe(
      id: 'postgres',
      name: 'PostgreSQL',
      category: RecipeCategory.database,
      description: 'PostgreSQL 16 database server.',
      image: 'postgres:16',
      containerName: 'wslm-postgres',
      port: 5432,
      credentials: 'user "postgres", password "postgres", db "postgres"',
      env: {'POSTGRES_PASSWORD': 'postgres'},
    ),
    ServiceRecipe(
      id: 'mysql',
      name: 'MySQL',
      category: RecipeCategory.database,
      description: 'MySQL 8 database server.',
      image: 'mysql:8',
      containerName: 'wslm-mysql',
      port: 3306,
      credentials: 'user "root", password "root", db "app"',
      env: {'MYSQL_ROOT_PASSWORD': 'root', 'MYSQL_DATABASE': 'app'},
    ),
    ServiceRecipe(
      id: 'clickhouse',
      name: 'ClickHouse',
      category: RecipeCategory.database,
      description: 'ClickHouse OLAP database with its HTTP play UI.',
      image: 'clickhouse/clickhouse-server:latest',
      containerName: 'wslm-clickhouse',
      port: 8123,
      dashboardPath: '/play',
      credentials: 'default user, no password',
      // Native protocol port alongside the HTTP one.
      extraArgs: ['-p', '9009:9000', '--ulimit', 'nofile=262144:262144'],
    ),
    ServiceRecipe(
      id: 'redis',
      name: 'Redis',
      category: RecipeCategory.database,
      description: 'Redis in-memory key/value store.',
      image: 'redis:7',
      containerName: 'wslm-redis',
      port: 6379,
      credentials: 'no auth (dev default)',
    ),

    // ----- Message brokers ----------------------------------------------
    ServiceRecipe(
      id: 'rabbitmq',
      name: 'RabbitMQ',
      category: RecipeCategory.broker,
      description: 'RabbitMQ broker with the management dashboard.',
      image: 'rabbitmq:3-management',
      containerName: 'wslm-rabbitmq',
      port: 15672,
      dashboardPath: '/',
      credentials: 'guest / guest',
      // AMQP port alongside the management UI.
      extraArgs: ['-p', '5672:5672'],
    ),
    ServiceRecipe(
      id: 'kafka',
      name: 'Kafka (Redpanda)',
      category: RecipeCategory.broker,
      description:
          'Kafka-compatible Redpanda broker with the Console dashboard.',
      image: 'redpandadata/redpanda:latest',
      containerName: 'wslm-kafka',
      port: 9092,
      credentials: 'no auth (dev default)',
      command:
          'redpanda start --overprovisioned --smp 1 --memory 1G --reserve-memory 0M '
          '--node-id 0 --check=false '
          '--kafka-addr PLAINTEXT://0.0.0.0:9092 '
          '--advertise-kafka-addr PLAINTEXT://127.0.0.1:9092',
    ),
  ];

  static List<ServiceRecipe> get all => recipes;

  static ServiceRecipe? byId(String id) {
    final needle = id.trim().toLowerCase();
    for (final recipe in recipes) {
      if (recipe.id == needle) return recipe;
    }
    return null;
  }

  static List<ServiceRecipe> inCategory(RecipeCategory category) =>
      recipes.where((r) => r.category == category).toList();
}
