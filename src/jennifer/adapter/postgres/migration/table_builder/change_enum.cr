module Jennifer
  module Postgres
    module Migration
      module TableBuilder
        class ChangeEnum < Base
          @effected_tables : Array(Array(DBAny))

          def initialize(adapter, name, @options : Hash(Symbol, Array(String)))
            super(adapter, name)
            @effected_tables = _effected_tables
          end

          def process
            remove_values if @options.has_key?(:remove_values)
            add_values if @options.has_key?(:add_values)
            rename_values if @options.has_key?(:rename_values)
            rename(name, @options[:new_name]) if @options.has_key?(:rename)
          end

          def remove_values
            new_values = [] of String
            adapter.enum_values(@name).map { |e| new_values << e[0] }
            new_values -= @options[:remove_values]
            if @effected_tables.empty?
              migration_processor.drop_enum(@name)
              migration_processor.define_enum(@name, new_values)
            else
              temp_name = "#{@name}_temp"
              migration_processor.define_enum(temp_name, new_values)
              @effected_tables.each do |row|
                @adapter.exec <<-SQL
                  ALTER TABLE #{row[0]} 
                  ALTER COLUMN #{row[1]} TYPE #{temp_name} 
                  USING (#{row[1]}::text::#{temp_name})
                SQL
                migration_processor.drop_enum(@name)
                rename(temp_name, @name)
              end
            end
          end

          def add_values
            typed_array_cast(@options[:add_values].as(Array), String).each do |field|
              adapter.exec "ALTER TYPE #{@name} ADD VALUE '#{field}'"
            end
          end

          def rename_values
            name = @name
            i = 0
            count = @options[:rename_values].as(Array).size
            while i < count
              old_name = @options[:rename_values][i]
              new_name = @options[:rename_values][i + 1]
              i += 2
              Query["pg_enum"].where do
                (c("enumlabel") == old_name) & (c("enumtypid") == sql("SELECT OID FROM pg_type WHERE typname = '#{name}'"))
              end.update({:enumlabel => new_name})
            end
          end

          def rename(old_name, new_name)
            adapter.exec "ALTER TYPE #{old_name} RENAME TO #{new_name}"
          end

          private def _effected_tables
            Query["information_schema.columns"]
              .select("table_name, column_name")
              .where { (c("udt_name") == @name.dup) & (c("table_catalog") == Config.db) }
              .pluck(:table_name, :column_name)
          end
        end
      end
    end
  end
end
