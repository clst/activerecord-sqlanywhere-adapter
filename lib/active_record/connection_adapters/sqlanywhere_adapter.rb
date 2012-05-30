#====================================================
#
#    Copyright 2008-2010 iAnywhere Solutions, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#
# See the License for the specific language governing permissions and
# limitations under the License.
#
# While not a requirement of the license, if you do modify this file, we
# would appreciate hearing about it.   Please email sqlany_interfaces@sybase.com
#
#
#====================================================

require 'active_record/connection_adapters/abstract_adapter'
require 'arel/visitors/sqlanywhere.rb'

# Singleton class to hold a valid instance of the SQLAnywhereInterface across all connections
class SA
  include Singleton
  attr_accessor :api

  def initialize
    require 'sqlanywhere' unless defined? SQLAnywhere
    @api = SQLAnywhere::SQLAnywhereInterface.new()
    raise LoadError, "Could not load SQLAnywhere DBCAPI library" if SQLAnywhere::API.sqlany_initialize_interface(@api) == 0
    raise LoadError, "Could not initialize SQLAnywhere DBCAPI library" if @api.sqlany_init() == 0
  end
end

module ActiveRecord
  class Base
    DEFAULT_CONFIG = { :username => 'dba', :password => 'sql' }
    # Main connection function to SQL Anywhere
    # Connection Adapter takes four parameters:
    # * :database (required, no default). Corresponds to "DatabaseName=" in connection string
    # * :server (optional, defaults to :databse). Corresponds to "ServerName=" in connection string
    # * :username (optional, default to 'dba')
    # * :password (optional, deafult to 'sql')
    # * :encoding (optional, defaults to charset of OS)
    # * :commlinks (optional). Corresponds to "CommLinks=" in connection string
    # * :connection_name (optional). Corresponds to "ConnectionName=" in connection string

    def self.sqlanywhere_connection(config)

      if config[:connection_string]
        connection_string = config[:connection_string]
      else
        config = DEFAULT_CONFIG.merge(config)

        raise ArgumentError, "No database name was given. Please add a :database option." unless config.has_key?(:database)

        connection_string = "ServerName=#{(config[:server] || config[:database])};DatabaseName=#{config[:database]};UserID=#{config[:username]};Password=#{config[:password]};"
        connection_string += "CommLinks=#{config[:commlinks]};" unless config[:commlinks].nil?
        connection_string += "ConnectionName=#{config[:connection_name]};" unless config[:connection_name].nil?
        connection_string += "CharSet=#{config[:encoding]};" unless config[:encoding].nil?
        connection_string += "Idle=0" # Prevent the server from disconnecting us if we're idle for >240mins (by default)
      end

      db = SA.instance.api.sqlany_new_connection()

      ConnectionAdapters::SQLAnywhereAdapter.new(db, logger, connection_string)
    end
  end

  module ConnectionAdapters
    class SQLAnywhereException < StandardError
      attr_reader :errno
      attr_reader :sql

      def initialize(message, errno, sql)
        super(message)
        @errno = errno
        @sql = sql
      end
    end

    class SQLAnywhereColumn < Column
      private
        # Overridden to handle SQL Anywhere integer, varchar, binary, and timestamp types
        def simplified_type(field_type)
          return :boolean if field_type =~ /tinyint/i
          return :boolean if field_type =~ /bit/i
          return :text if field_type =~ /long varchar/i
          return :string if field_type =~ /varchar/i
          return :binary if field_type =~ /long binary/i
          return :datetime if field_type =~ /timestamp/i
          return :integer if field_type =~ /smallint|bigint/i
          super
        end

        def extract_limit(sql_type)
          case sql_type
            when /^tinyint/i
              1
            when /^smallint/i
              2
            when /^integer/i
              4
            when /^bigint/i
              8
            else super
          end
        end

      protected
        # Handles the encoding of a binary object into SQL Anywhere
        # SQL Anywhere requires that binary values be encoded as \xHH, where HH is a hexadecimal number
        # This function encodes the binary string in this format
        def self.string_to_binary(value)
          "\\x" + value.unpack("H*")[0].scan(/../).join("\\x")
        end

        def self.binary_to_string(value)
          value.gsub(/\\x[0-9]{2}/) { |byte| byte[2..3].hex }
        end

		# Should override the time column values.
		# Sybase doesn't like the time zones.
		# use config.active_record.time_zone_aware_attributes = false for local time
		# TODO: look into TIMESTAMP WITH TIME ZONE
		# see binds in exec_query

    end

    class SQLAnywhereAdapter < AbstractAdapter
      def initialize( connection, logger, connection_string = "") #:nodoc:
        super(connection, logger)
        @auto_commit = true
        @affected_rows = 0
        @connection_string = connection_string
        @visitor = Arel::Visitors::SQLAnywhere.new self
        connect!
      end

      def self.visitor_for(pool)
        config = pool.spec.config

        if config.fetch(:prepared_statements) {true}
          Arel::Visitors::SQLAnywhere.new pool
        else
          BindSubstitution.new pool
        end
      end

      def adapter_name #:nodoc:
        'SQLAnywhere'
      end

      def supports_migrations? #:nodoc:
        true
      end

      def requires_reloading?
        true
      end

      def active?
        # The liveness variable is used a low-cost "no-op" to test liveness
        SA.instance.api.sqlany_execute_immediate(@connection, "SET liveness = 1") == 1
      rescue
        false
      end

      def disconnect!
        result = SA.instance.api.sqlany_disconnect( @connection )
        super
      end

      def reconnect!
        disconnect!
        connect!
      end

      def supports_count_distinct? #:nodoc:
        true
      end

      def supports_autoincrement? #:nodoc:
        true
      end

      # Maps native ActiveRecord/Ruby types into SQLAnywhere types
      # TINYINTs are treated as the default boolean value
      # ActiveRecord allows NULLs in boolean columns, and the SQL Anywhere BIT type does not
      # As a result, TINYINT must be used. All TINYINT columns will be assumed to be boolean and
      # should not be used as single-byte integer columns. This restriction is similar to other ActiveRecord database drivers
      def native_database_types #:nodoc:
        {
          :primary_key => 'INTEGER PRIMARY KEY DEFAULT AUTOINCREMENT NOT NULL',
          :string      => { :name => "varchar", :limit => 255 },
          :text        => { :name => "long varchar" },
          :integer     => { :name => "integer", :limit => 4 },
          :float       => { :name => "float" },
          :decimal     => { :name => "decimal" },
          :datetime    => { :name => "datetime" },
          :timestamp   => { :name => "datetime" },
          :time        => { :name => "time" },
          :date        => { :name => "date" },
          :binary      => { :name => "long binary" },
          :boolean     => { :name => "tinyint", :limit => 1}
        }
      end

      # QUOTING ==================================================

      # Applies quotations around column names in generated queries
      def quote_column_name(name) #:nodoc:
        %Q("#{name}")
      end

      # Handles special quoting of binary columns. Binary columns will be treated as strings inside of ActiveRecord.
      # ActiveRecord requires that any strings it inserts into databases must escape the backslash (\).
      # Since in the binary case, the (\x) is significant to SQL Anywhere, it cannot be escaped.
      def quote(value, column = nil)
        case value
          when String, ActiveSupport::Multibyte::Chars
            value_S = value.to_s
            if column && column.type == :binary && column.class.respond_to?(:string_to_binary)
              "'#{column.class.string_to_binary(value_S)}'"
            else
               super(value, column)
            end
          else
            super(value, column)
        end
      end

      def quoted_true
        '1'
      end

      def quoted_false
        '0'
      end


      # This function (distinct) is based on the Oracle Enhacned ActiveRecord driver maintained by Raimonds Simanovskis (2010)
      # (https://github.com/rsim/oracle-enhanced)
      def distinct(columns, order_by) #:nodoc:
        return "DISTINCT #{columns}" if order_by.blank?

        # construct a valid DISTINCT clause, ie. one that includes the ORDER BY columns, using
        # FIRST_VALUE such that the inclusion of these columns doesn't invalidate the DISTINCT
        order_columns = if order_by.is_a?(String)
          order_by.split(',').map { |s| s.strip }.reject(&:blank?)
        else # in latest ActiveRecord versions order_by is already Array
          order_by
        end
        order_columns = order_columns.zip((0...order_columns.size).to_a).map do |c, i|
          # remove any ASC/DESC modifiers
          value = c =~ /^(.+)\s+(ASC|DESC)\s*$/i ? $1 : c
          "FIRST_VALUE(#{value}) OVER (PARTITION BY #{columns} ORDER BY #{c}) AS alias_#{i}__"
        end
        sql = "DISTINCT #{columns}, "
        sql << order_columns * ", "
      end

      # The database execution function
      def execute(sql, name = nil) #:nodoc:
        if name == :skip_logging
          r = SA.instance.api.sqlany_execute_immediate(@connection, sql)
          sqlanywhere_error_test(sql) if r==0
        else
          log(sql, name) { execute(sql, :skip_logging) }
        end
      end

      def sqlanywhere_error_test(sql = '')
        error_code, error_message = SA.instance.api.sqlany_error(@connection)
        if error_code != 0
          sqlanywhere_error(error_code, error_message, sql)
        end
      end

      def sqlanywhere_error(code, message, sql)
        raise SQLAnywhereException.new(message, code, sql)
      end

      def translate_exception(exception, message)
        return super unless exception.respond_to?(:errno)
        case exception.errno
          when -143
            if exception.sql !~ /^SELECT/i then
              raise ActiveRecord::ActiveRecordError.new(message)
            else
              super
            end
          when -194
            raise InvalidForeignKey.new(message, exception)
          when -196
            raise RecordNotUnique.new(message, exception)
          when -183
            raise ArgumentError, message
          else
            super
        end
      end

      # The database update function.
      def update_sql(sql, name = nil)
        execute( sql, name )
        return @affected_rows
      end

      # The database delete function.
      def delete_sql(sql, name = nil) #:nodoc:
        execute( sql, name )
        return @affected_rows
      end

      # The database insert function.
      # ActiveRecord requires that insert_sql returns the primary key of the row just inserted. In most cases, this can be accomplished
      # by immediatly querying the @@identity property. If the @@identity property is 0, then passed id_value is used
      def insert_sql(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil) #:nodoc:
        execute(sql, name)

        retval =  last_inserted_id(nil)
        retval = id_value if retval == 0
        return retval
      end

      def exec_delete(sql, name = 'SQL', binds = [])
        exec_query(sql, name, binds)
        @affected_rows
      end
      alias :exec_update :exec_delete

      def last_inserted_id(result)
        identity = SA.instance.api.sqlany_execute_direct(@connection, 'SELECT @@identity')
        raise ActiveRecord::StatementInvalid.new("#{SA.instance.api.sqlany_error(@connection)}:#{sql}") if identity.nil?
        SA.instance.api.sqlany_fetch_next(identity)
        retval = SA.instance.api.sqlany_get_column(identity, 0)[1]
        SA.instance.api.sqlany_free_stmt(identity)

        return retval
      end

      # Returns a query as an array of arrays
      def select_rows(sql, name = nil)
        rs = SA.instance.api.sqlany_execute_direct(@connection, sql)
        raise ActiveRecord::StatementInvalid.new("#{SA.instance.api.sqlany_error(@connection)}:#{sql}") if rs.nil?
        record = []
        while SA.instance.api.sqlany_fetch_next(rs) == 1
          max_cols = SA.instance.api.sqlany_num_cols(rs)
          result = Array.new(max_cols)
          max_cols.times do |cols|
            result[cols] = SA.instance.api.sqlany_get_column(rs, cols)[1]
          end
          record << result
        end
        SA.instance.api.sqlany_free_stmt(rs)
        return record
      end

      def begin_db_transaction #:nodoc:
        @auto_commit = false;
      end

      def commit_db_transaction #:nodoc:
        SA.instance.api.sqlany_commit(@connection)
        @auto_commit = true;
      end

      def rollback_db_transaction #:nodoc:
        SA.instance.api.sqlany_rollback(@connection)
        @auto_commit = true;
      end

      def add_lock!(sql, options) #:nodoc:
        sql
      end

      # SQL Anywhere does not support sizing of integers based on the sytax INTEGER(size). Integer sizes
      # must be captured when generating the SQL and replaced with the appropriate size.
      def type_to_sql(type, limit = nil, precision = nil, scale = nil) #:nodoc:
        type = type.to_sym
        if native = native_database_types[type]
          if type == :integer
            case limit
              when 1
                column_type_sql = 'tinyint'
              when 2
                column_type_sql = 'smallint'
              when 3..4
                column_type_sql = 'integer'
              when 5..8
                column_type_sql = 'bigint'
              else
                column_type_sql = 'integer'
            end
               column_type_sql
          elsif type == :string and !limit.nil?
             "varchar (#{limit})"
          elsif type == :boolean
            column_type_sql = 'tinyint'
          else
            super(type, limit, precision, scale)
          end
        else
          super(type, limit, precision, scale)
        end
      end

      # Do not return SYS-owned or DBO-owned tables or RS_systabgroup-owned
      def tables(name = nil) #:nodoc:
          sql = "SELECT table_name FROM SYS.SYSTABLE WHERE creator NOT IN (0,3,5)"
          select(sql, name).map { |row| row["table_name"] }
      end

      def columns(table_name, name = nil) #:nodoc:
        table_structure(table_name).map do |field|
          SQLAnywhereColumn.new(field['name'], field['default'], field['domain'], (field['nulls'] == 1))
        end
      end

      def indexes(table_name, name = nil) #:nodoc:
        if @major_version <= 11 # the sql doesn't work in older databases.
          return []
        end
        sql = "SELECT DISTINCT index_name, \"unique\" FROM SYS.SYSTABLE INNER JOIN SYS.SYSIDXCOL ON SYS.SYSTABLE.table_id = SYS.SYSIDXCOL.table_id INNER JOIN SYS.SYSIDX ON SYS.SYSTABLE.table_id = SYS.SYSIDX.table_id AND SYS.SYSIDXCOL.index_id = SYS.SYSIDX.index_id WHERE table_name = '#{table_name}' AND index_category > 2"
        select(sql, name).map do |row|
          index = IndexDefinition.new(table_name, row['index_name'])
          index.unique = row['unique'] == 1
          sql = "SELECT column_name FROM SYS.SYSIDX INNER JOIN SYS.SYSIDXCOL ON SYS.SYSIDXCOL.table_id = SYS.SYSIDX.table_id AND SYS.SYSIDXCOL.index_id = SYS.SYSIDX.index_id INNER JOIN SYS.SYSCOLUMN ON SYS.SYSCOLUMN.table_id = SYS.SYSIDXCOL.table_id AND SYS.SYSCOLUMN.column_id = SYS.SYSIDXCOL.column_id WHERE index_name = '#{row['index_name']}'"
          index.columns = select(sql).map { |col| col['column_name'] }
          index
        end
      end

      def primary_key(table_name) #:nodoc:
        sql = "SELECT cname from SYS.SYSCOLUMNS where tname = '#{table_name}' and in_primary_key = 'Y'"
        rs = exec_query(sql)
        if !rs.nil? and !rs.first.nil?
          rs.first['cname']
        else
          nil
        end
      end

      def remove_index(table_name, options={}) #:nodoc:
        execute "DROP INDEX #{quote_table_name(table_name)}.#{quote_column_name(index_name(table_name, options))}"
      end

      def rename_table(name, new_name)
        execute "ALTER TABLE #{quote_table_name(name)} RENAME #{quote_table_name(new_name)}"
      end

      def change_column_default(table_name, column_name, default) #:nodoc:
        execute "ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} DEFAULT #{quote(default)}"
      end

      def change_column_null(table_name, column_name, null, default = nil)
        unless null || default.nil?
          execute("UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(column_name)}=#{quote(default)} WHERE #{quote_column_name(column_name)} IS NULL")
        end
        execute("ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} #{null ? '' : 'NOT'} NULL")
      end

      def change_column(table_name, column_name, type, options = {}) #:nodoc:
        add_column_sql = "ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
        add_column_options!(add_column_sql, options)
        add_column_sql << ' NULL' if options[:null]
        execute(add_column_sql)
      end

      def rename_column(table_name, column_name, new_column_name) #:nodoc:
        if column_name.downcase == new_column_name.downcase
          whine = "if_the_only_change_is_case_sqlanywhere_doesnt_rename_the_column"
          rename_column table_name, column_name, "#{new_column_name}#{whine}"
          rename_column table_name, "#{new_column_name}#{whine}", new_column_name
        else
          execute "ALTER TABLE #{quote_table_name(table_name)} RENAME #{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}"
        end
      end

      def remove_column(table_name, *column_names)
        column_names = column_names.flatten
        column_names.zip(columns_for_remove(table_name, *column_names)).each do |unquoted_column_name, column_name|
          sql = <<-SQL
            SELECT "index_name" FROM SYS.SYSTAB join SYS.SYSTABCOL join SYS.SYSIDXCOL join SYS.SYSIDX
            WHERE "column_name" = '#{unquoted_column_name}' AND "table_name" = '#{table_name}'
          SQL
          select(sql, nil).each do |row|
            execute "DROP INDEX \"#{table_name}\".\"#{row['index_name']}\""
          end
          execute "ALTER TABLE #{quote_table_name(table_name)} DROP #{column_name}"
        end
      end


      def purge_database
        tables.each do |table_name|
          drop_table(table_name)
        end
      end

      protected
        def select(sql, name = nil, binds = []) #:nodoc:
           exec_query(sql, name, binds).to_a
        end

        # ActiveRecord uses the OFFSET/LIMIT keywords at the end of query to limit the number of items in the result set.
        # This syntax is NOT supported by SQL Anywhere. In previous versions of this adapter this adapter simply
        # overrode the add_limit_offset function and added the appropriate TOP/START AT keywords to the start of the query.
        # However, this will not work for cases where add_limit_offset is being used in a subquery since add_limit_offset
        # is called with the WHERE clause.
        #
        # As a result, the following function must be called before every SELECT statement against the database. It
        # recursivly walks through all subqueries in the SQL statment and replaces the instances of OFFSET/LIMIT with the
        # corresponding TOP/START AT. It was my intent to do the entire thing using regular expressions, but it would seem
        # that it is not possible given that it must count levels of nested brackets.
        def modify_limit_offset(sql)
          modified_sql = ""
          subquery_sql = ""
          in_single_quote = false
          in_double_quote = false
          nesting_level = 0
          if sql =~ /(OFFSET|LIMIT)/xmi then
            if sql =~ /\(/ then
              sql.split(//).each_with_index do |x, i|
                case x[0]
                  when 40  # left brace - (
                    modified_sql << x if nesting_level == 0
                    subquery_sql << x if nesting_level > 0
                    nesting_level = nesting_level + 1 unless in_double_quote || in_single_quote
                  when 41  # right brace - )
                    nesting_level = nesting_level - 1 unless in_double_quote || in_single_quote
                    if nesting_level == 0 and !in_double_quote and !in_single_quote then
                      modified_sql << modify_limit_offset(subquery_sql)
                      subquery_sql = ""
                    end
                    modified_sql << x if nesting_level == 0
                    subquery_sql << x if nesting_level > 0
                  when 39  # single quote - '
                    in_single_quote = in_single_quote ^ true unless in_double_quote
                    modified_sql << x if nesting_level == 0
                    subquery_sql << x if nesting_level > 0
                  when 34  # double quote - "
                    in_double_quote = in_double_quote ^ true unless in_single_quote
                    modified_sql << x if nesting_level == 0
                    subquery_sql << x if nesting_level > 0
                  else
                    modified_sql << x if nesting_level == 0
                    subquery_sql << x if nesting_level > 0
                end
                raise ActiveRecord::StatementInvalid.new("Braces do not match: #{sql}") if nesting_level < 0
              end
            else
              modified_sql = sql
            end
            raise ActiveRecord::StatementInvalid.new("Quotes do not match: #{sql}") if in_double_quote or in_single_quote
            return "" if modified_sql.nil?
            select_components = modified_sql.scan(/\ASELECT\s+(DISTINCT)?(.*?)(?:\s+LIMIT\s+(.*?))?(?:\s+OFFSET\s+(.*?))?\Z/xmi)
            return modified_sql if select_components[0].nil?
            final_sql = "SELECT #{select_components[0][0]} "
            final_sql << "TOP #{select_components[0][2].nil? ? 1000000 : select_components[0][2]} "
            final_sql << "START AT #{(select_components[0][3].to_i + 1).to_s} " unless select_components[0][3].nil?
            final_sql << "#{select_components[0][1]}"
            return final_sql
          else
            return sql
          end
        end

        # Queries the structure of a table including the columns names, defaults, type, and nullability
        # ActiveRecord uses the type to parse scale and precision information out of the types. As a result,
        # chars, varchars, binary, nchars, nvarchars must all be returned in the form <i>type</i>(<i>width</i>)
        # numeric and decimal must be returned in the form <i>type</i>(<i>width</i>, <i>scale</i>)
        # Nullability is returned as 0 (no nulls allowed) or 1 (nulls allowed)
        # Alos, ActiveRecord expects an autoincrement column to have default value of NULL

        def table_structure(table_name)
          sql = <<-SQL
SELECT SYS.SYSCOLUMN.column_name AS name,
  if left("default",1)='''' then substring("default", 2, length("default")-2) // remove the surrounding quotes
  else NULLIF(SYS.SYSCOLUMN."default", 'autoincrement')
  endif AS "default",
  IF SYS.SYSCOLUMN.domain_id IN (7,8,9,11,33,34,35,3,27) THEN
    IF SYS.SYSCOLUMN.domain_id IN (3,27) THEN
      SYS.SYSDOMAIN.domain_name || '(' || SYS.SYSCOLUMN.width || ',' || SYS.SYSCOLUMN.scale || ')'
    ELSE
      SYS.SYSDOMAIN.domain_name || '(' || SYS.SYSCOLUMN.width || ')'
    ENDIF
  ELSE
    SYS.SYSDOMAIN.domain_name
  ENDIF AS domain,
  IF SYS.SYSCOLUMN.nulls = 'Y' THEN 1 ELSE 0 ENDIF AS nulls
FROM
  SYS.SYSCOLUMN
  INNER JOIN SYS.SYSTABLE ON SYS.SYSCOLUMN.table_id = SYS.SYSTABLE.table_id
  INNER JOIN SYS.SYSDOMAIN ON SYS.SYSCOLUMN.domain_id = SYS.SYSDOMAIN.domain_id
WHERE
  table_name = '#{table_name}'
SQL
          structure = exec_query(sql, :skip_logging)
          raise(ActiveRecord::StatementInvalid, "Could not find table '#{table_name}'") if structure == false
          structure
        end

        # Required to prevent DEFAULT NULL being added to primary keys
        def options_include_default?(options)
          options.include?(:default) && !(options[:null] == false && options[:default].nil?)
        end

      private

        def connect!
          result = SA.instance.api.sqlany_connect(@connection, @connection_string)
          if result == 1 then
            set_connection_options
          else
            error = SA.instance.api.sqlany_error(@connection)
            raise ActiveRecord::ActiveRecordError.new("#{error}: Cannot Establish Connection")
          end
          version = exec_query('select @@version').rows[0][0]
          @major_version = /^\d+/.match(version).to_s.to_i
        end

        def set_connection_options
          SA.instance.api.sqlany_execute_immediate(@connection, "SET TEMPORARY OPTION non_keywords = 'LOGIN'") rescue nil
          SA.instance.api.sqlany_execute_immediate(@connection, "SET TEMPORARY OPTION timestamp_format = 'YYYY-MM-DD HH:NN:SS'") rescue nil
          #SA.instance.api.sqlany_execute_immediate(@connection, "SET OPTION reserved_keywords = 'LIMIT'") rescue nil
          # The liveness variable is used a low-cost "no-op" to test liveness
          SA.instance.api.sqlany_execute_immediate(@connection, "CREATE VARIABLE liveness INT") rescue nil
        end

        def exec_query(sql, name = 'SQL', binds = [])
          log(sql, name, binds) do
            stmt = SA.instance.api.sqlany_prepare(@connection, sql)

            if stmt.nil?
              sqlanywhere_error_test(sql)
            end

            for i in 0...binds.length
              bind_type = binds[i][0].type
              bind_value = binds[i][1]
              result, bind_param = SA.instance.api.sqlany_describe_bind_param(stmt, i)
              sqlanywhere_error_test(sql) if result==0

              bind_param.set_direction(1) # https://github.com/sqlanywhere/sqlanywhere/blob/master/ext/sacapi.h#L175
              if bind_value.nil?
                bind_param.set_value(nil)
              elsif [:datetime, :date].include? bind_type
                bind_param.set_value(bind_value.to_s :db)
              elsif bind_type == :boolean
                bind_param.set_value(bind_value ? 1 : 0)
              elsif bind_type == :decimal
                bind_param.set_value(bind_value.to_s)
              else
                bind_param.set_value(bind_value)
              end
              result = SA.instance.api.sqlany_bind_param(stmt, i, bind_param)
              sqlanywhere_error_test(sql) if result==0

            end

            if SA.instance.api.sqlany_execute(stmt) == 0
              sqlanywhere_error_test(sql)
            end

            fields = []
            native_types = []

            num_cols = SA.instance.api.sqlany_num_cols(stmt)
            sqlanywhere_error_test(sql) if num_cols == -1

            for i in 0...num_cols
              result, col_num, name, ruby_type, native_type, precision, scale, max_size, nullable = SA.instance.api.sqlany_get_column_info(stmt, i)
              sqlanywhere_error_test(sql) if result==0
              #always use database encoding for the column names (like in SQLite)
	      #this fixes to_yaml outputting all column names with !binary
	      fields << name.force_encoding(ActiveRecord::Base.configurations[Rails.env]['encoding'])
              native_types << native_type
            end
            rows = []
            while SA.instance.api.sqlany_fetch_next(stmt) == 1
              row = []
              for i in 0...num_cols
                r, value = SA.instance.api.sqlany_get_column(stmt, i)
                row << native_type_to_ruby_type(native_types[i], value)
              end
              rows << row
            end
            SA.instance.api.sqlany_free_stmt(stmt)

            if @auto_commit
              result = SA.instance.api.sqlany_commit(@connection)
              sqlanywhere_error_test(sql) if result==0
            end
            return ActiveRecord::Result.new(fields, rows)
          end
        end

        def query(sql)
          return if sql.nil?
          #sql = modify_limit_offset(sql)

          # ActiveRecord allows a query to return TOP 0. SQL Anywhere requires that the TOP value is a positive integer.
          return Array.new() if sql =~ /TOP 0/i

          # Executes the query, iterates through the results, and builds an array of hashes.
          rs = SA.instance.api.sqlany_execute_direct(@connection, sql)
          if rs.nil?
            result, errstr = SA.instance.api.sqlany_error(@connection)
            raise SQLAnywhereException.new(errstr, result, sql)
          end

          record = []
          if( SA.instance.api.sqlany_num_cols(rs) > 0 )
            while SA.instance.api.sqlany_fetch_next(rs) == 1
              max_cols = SA.instance.api.sqlany_num_cols(rs)
              result = Hash.new()
              max_cols.times do |cols|
              col_content=SA.instance.api.sqlany_get_column(rs, cols)[1]
              if !col_content.nil? && col_content.is_a?(String)
                puts ":encoding missing in database.yml" if ActiveRecord::Base.configurations[Rails.env]['encoding'].nil?
                col_content = col_content.force_encoding(ActiveRecord::Base.configurations[Rails.env]['encoding'])
              end
                result[SA.instance.api.sqlany_get_column_info(rs, cols)[2]] = col_content
              end
              record << result
            end
            @affected_rows = 0
          else
            @affected_rows = SA.instance.api.sqlany_affected_rows(rs)
          end
          SA.instance.api.sqlany_free_stmt(rs)

          SA.instance.api.sqlany_commit(@connection) if @auto_commit
          return record
        end

        # convert sqlany type to ruby type
        # the types are taken from here
        # http://dcx.sybase.com/1101/en/dbprogramming_en11/pg-c-api-native-type-enum.html
        def native_type_to_ruby_type(native_type, value)
          return nil if value.nil?
          case native_type
          when 484 # DT_DECIMAL (also and more importantly numeric)
            BigDecimal.new(value)
	  when 448,452,456,460,640  # DT_VARCHAR, DT_FIXCHAR, DT_LONGVARCHAR, DT_STRING, DT_LONGNVARCHAR
	    #The C API usually returns ASCII-8BIT (Ruby or Sybase-Bug?)
	    #Always force encoding to match database connection encoding for Strings (expected behavior?)
	    value.force_encoding(ActiveRecord::Base.configurations[Rails.env]['encoding'])
	  else
            value
          end
        end
    end
  end
end
