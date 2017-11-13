require "pg"
require "../adapter"
require "./base"

require "./postgres/result_set"
require "./postgres/field"
require "./postgres/exec_result"

require "./postgres/sql_generator"
require "./postgres/migration_processor"

module Jennifer
  module Postgres
    class Adapter < Adapter::Base
      alias EnumType = Bytes

      TYPE_TRANSLATIONS = {
        :integer => "int",      # Int32
        :short   => "SMALLINT", # Int16
        :bigint  => "BIGINT",   # Int64
        :oid     => "oid",      # UInt32

        :float  => "real",             # Float32
        :double => "double precision", # Float64

        :numeric => "numeric", # PG::Numeric
        :decimal => "decimal", # PG::Numeric - is alias for numeric

        :string     => "varchar",
        :char       => "char",
        :bool       => "boolean",
        :text       => "text",
        :var_string => "varchar",
        :varchar    => "varchar",
        :blchar     => "blchar", # String

        :uuid => "uuid", # String

        :timestamp   => "timestamp",
        :timestamptz => "timestamptz", # Time
        :date_time   => "datetime",

        :blob  => "blob",
        :bytea => "bytea",

        :json  => "json",  # JSON
        :jsonb => "jsonb", # JSON
        :xml   => "xml",   # String

        :point   => "point",
        :lseg    => "lseg",
        :path    => "path",
        :box     => "box",
        :polygon => "polygon",
        :line    => "line",
        :circle  => "circle",
      }

      DEFAULT_SIZES = {
        :string     => 254,
        :var_string => 254,
      }

      TABLE_LOCK_TYPES = {
        "as"      => "ACCESS SHARE",
        "rs"      => "ROW SHARE",
        "re"      => "ROW EXCLUSIVE",
        "sue"     => "SHARE UPDATE EXCLUSIVE",
        "s"       => "SHARE",
        "sre"     => "SHARE ROW EXCLUSIVE",
        "e"       => "EXCLUSIVE",
        "ae"      => "ACCESS EXCLUSIVE",
        "default" => "SHARE", # "s"
      }

      def sql_generator
        SQLGenerator
      end

      def migration_processor
        @migration_processor ||= MigrationProcessor.new(self)
      end

      def prepare
        _query = <<-SQL
          SELECT e.enumtypid
          FROM pg_type t, pg_enum e
          WHERE t.oid = e.enumtypid
        SQL

        query(_query) do |rs|
          rs.each do
            PG::Decoders.register_decoder PG::Decoders::StringDecoder.new, rs.read(UInt32).to_i
          end
        end
        super
      end

      def translate_type(name)
        TYPE_TRANSLATIONS[name]
      rescue e : KeyError
        raise BaseException.new("Unknown data alias #{name}")
      end

      def default_type_size(name)
        DEFAULT_SIZES[name]?
      end

      def refresh_materialized_view(name)
        exec "REFRESH MATERIALIZED VIEW #{name}"
      end

      def table_column_count(table)
        if table_exists?(table)
          Query["information_schema.columns"].where { _table_name == table }.count
        elsif material_view_exists?(table)
          # materialized view
          Query["pg_attribute"]
            .join("pg_class") { _pg_attribute__attrelid == _oid }
            .join("pg_namespace") { _oid == _pg_class__relnamespace }
            .where do
            (_attnum > 0) &
              (_pg_namespace__nspname == Config.schema) &
              (_pg_class__relname == table) &
              _attisdropped.not
          end.count
        else
          -1
        end
      end

      def material_view_exists?(name)
        Query["pg_class"].join("pg_namespace") { _oid == _pg_class__relnamespace }.where do
          (_relkind == "m") &
            (_pg_namespace__nspname == Config.schema) &
            (_relname == name)
        end.exists?
      end

      def table_exists?(table)
        Query["information_schema.tables"]
          .where { _table_name == table }
          .exists?
      end

      def column_exists?(table, name)
        Query["information_schema.columns"]
          .where { (_table_name == table) & (_column_name == name) }
          .exists?
      end

      def index_exists?(table, name)
        Query["pg_class"]
          .join("pg_namespace") { _oid == _pg_class__relnamespace }
          .where { (_pg_class__relname == name) & (_pg_namespace__nspname == Config.schema) }
          .exists?
      end

      def view_exists?(name)
        Query["information_schema.views"]
          .where { (_table_schema == Config.schema) & (_table_name == name) }
          .exists?
      end

      def data_type_exists?(name)
        Query["pg_type"].where { _typname == name }.exists?
      end

      def enum_values(name)
        query_array("SELECT unnest(enum_range(NULL::#{name})::varchar[])", String).map { |array| array[0] }
      end

      def with_table_lock(table : String, type : String = "default", &block)
        transaction do |t|
          exec "LOCK TABLE #{table} IN #{TABLE_LOCK_TYPES[type]} MODE"
          yield t
        end
      rescue e : KeyError
        raise BaseException.new("Unknown table lock type '#{type}'.")
      end

      def insert(obj : Model::Base)
        opts = obj.arguments_to_insert
        query = parse_query(sql_generator.insert(obj, obj.class.primary_auto_incrementable?), opts[:args])
        id = -1i64
        affected = 0i64
        if obj.class.primary_auto_incrementable?
          # TODO: move this back when pg driver will raise exception when inserted record brake some constraint
          # id = scalar(query, opts[:args]).as(Int32).to_i64
          # affected += 1 if id > 0
          affected = exec(query, opts[:args]).rows_affected
          if affected != 0
            id = scalar("SELECT currval(pg_get_serial_sequence('#{obj.class.table_name}', '#{obj.class.primary_field_name}'))").as(Int64)
          end
        else
          affected = exec(query, opts[:args]).rows_affected
        end

        ExecResult.new(id, affected)
      end

      def self.bulk_insert(collection : Array(Model::Base))
        opts = collection.flat_map(&.arguments_to_insert[:args])
        query = parse_query(sql_generator.bulk_insert(collection))
        # TODO: change to checking for autoincrementability
        affected = exec(qyery, opts).rows_affected
        if true
          if affected == collection.size
          else
            raise ::Jennifer::BaseException.new("Bulk insert failed with #{collection.size - affected} records.")
          end
        end
      end

      def exists?(query)
        args = query.select_args
        body = sql_generator.exists(query)
        scalar(body, args)
      end

      def self.create_database
        opts = [Config.db, "-O", Config.user, "-h", Config.host, "-U", Config.user]
        Process.run("PGPASSWORD=#{Config.password} createdb \"${@}\"", opts, shell: true).inspect
      end

      def self.drop_database
        io = IO::Memory.new
        opts = [Config.db, "-h", Config.host, "-U", Config.user]
        s = Process.run("PGPASSWORD=#{Config.password} dropdb \"${@}\"", opts, shell: true, output: io, error: io)
        if s.exit_code != 0
          raise io.to_s
        end
      end

      def self.generate_schema
        io = IO::Memory.new
        opts = ["-U", Config.user, "-d", Config.db, "-h", Config.host, "-s"]
        s = Process.run("PGPASSWORD=#{Config.password} pg_dump \"${@}\"", opts, shell: true, output: io)
        File.write(Config.structure_path, io.to_s)
      end

      def self.load_schema
        io = IO::Memory.new
        opts = ["-U", Config.user, "-d", Config.db, "-h", Config.host, "-a", "-f", Config.structure_path]
        s = Process.run("PGPASSWORD=#{Config.password} psql \"${@}\"", opts, shell: true, output: io)
        raise "Cant load schema: exit code #{s.exit_code}" if s.exit_code != 0
      end
    end
  end
end

require "./postgres/criteria"
require "./postgres/numeric"
require "./postgres/migration/table_builder/base"
require "./postgres/migration/table_builder/*"

::Jennifer::Adapter.register_adapter("postgres", ::Jennifer::Postgres::Adapter)
