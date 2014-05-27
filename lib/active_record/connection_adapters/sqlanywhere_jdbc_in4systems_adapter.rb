#encoding: utf-8
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
#require 'active_record'
require 'activerecord-jdbc-adapter'

require 'active_record/connection_adapters/abstract_adapter'
require 'arel/visitors/sqlanywhere.rb'
require 'pathname'

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

    def self.sqlanywhere_jdbc_in4systems_connection(config)

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

      url = 'jdbc:sqlanywhere:' + connection_string

      if ENV['SQLANY12']
        $CLASSPATH << 'sajdbc4.jar'
        $CLASSPATH << Pathname.new(ENV['SQLANY12']).join('java').join('sajdbc4.jar').to_s
        driver = 'sybase.jdbc4.sqlanywhere.IDriver'
      elsif ENV['SQLANY11']
        $CLASSPATH << 'sajdbc.jar'
        $CLASSPATH << Pathname.new(ENV['SQLANY11']).join('java').join('sajdbc.jar').to_s
        driver = 'sybase.jdbc.sqlanywhere.IDriver'
      else
        raise "Cannot find SqlAnywhere11 or 12 installation directory"
      end

      conn = ActiveRecord::Base.jdbc_connection({adapter: 'jdbc', driver: driver, url: url})

      ConnectionAdapters::SQLAnywhereJdbcIn4systemsAdapter.new( conn, logger, connection_string)
    end
  end

  module ConnectionAdapters
    class JdbcTypeConverter
      AR_TO_JDBC_TYPES[:text] << lambda {|r| r['type_name'] =~ /^long varchar$/i}
    end

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
          return :text if field_type =~ /xml/i
          return :integer if field_type =~ /uniqueidentifier/i
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

    end

    class SQLAnywhereJdbcIn4systemsAdapter < AbstractAdapter
      delegate :select, :select_rows, :execute, to: :conn

      attr_reader :conn
      def initialize( conn, logger, connection_string = "") #:nodoc:
        super
        @visitor = Arel::Visitors::SQLAnywhere.new self
        @conn = conn
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
          :binary      => { :name => "binary" },
          :boolean     => { :name => "tinyint", :limit => 1}
        }
      end

      # QUOTING ==================================================

      # Applies quotations around column names in generated queries
      def quote_column_name(name) #:nodoc:
        %Q("#{name}")
      end

      def quote_table_name(name)
        owner, table = name.to_s.split('.', 2)
        if table == nil
          table = owner
          owner = :dba
        end
        "#{quote_column_name(owner)}.#{quote_column_name(table)}"
      end

      def quote_table_alias_name(name)
        quote_column_name name
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

      def viewed_tables(name = nil)
        list_of_tables(['view'], name)
      end

      def base_tables(name = nil)
        list_of_tables(['base'], name)
      end

      # Do not return SYS-owned or DBO-owned tables or RS_systabgroup-owned
      def tables(name = nil) #:nodoc:
        list_of_tables(['base', 'view'])
      end

      def columns(table_name, name = nil) #:nodoc:
        table_structure(table_name).map do |field|
          default = field['default']
          if default == nil # Nil is the usual case
          elsif default.starts_with?("'") # If string, remove first and last quotes and the last \n character
            default = default[1..-2]
          elsif default =~ /^-?\d+(\.\d+)?$/ # If a number string, leave as it is
          else # Otherwise, it's probably something (LAST USER, CURRENT TIMESTAMP, etc) that wouldn't work in Rails, so return nil
            default = nil
          end
          SQLAnywhereColumn.new(field['name'], default, field['domain'], (field['nulls'] == 1))
        end
      end

      def indexes(table_name, name = nil) #:nodoc:
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

      def exec_query(sql, name = 'SQL', binds = [])
        binds.map! do |column, value|
          type = column.type
          if value != nil
            case type
            when :boolean
              [column, value ? 1 : 0]
            else
              [column, value]
            end
          else
            [column, value]
          end
        end
        conn.exec_query(sql, name, binds)
      end

      def last_inserted_id(result)
        select_value('SELECT @@identity')
      end

      def select_user(cache=true)
        @user_id = (cache && @user_id) || select_value('SELECT USER')
      end

      # Set the database user to be user_id.
      # If a block is given, then after running the block, the previous user_id is restored.
      def set_user(user_id)
        previous_user_id = select_user(true)
        if previous_user_id != user_id
          execute("SETUSER #{quote_column_name(user_id)}")
          @user_id = user_id
        end
        if block_given?
          begin
            yield
          ensure
            set_user(previous_user_id)
          end
        end
      end

      protected

        def list_of_tables(types, name = nil)
          sql = "SELECT table_name FROM SYS.SYSTABLE WHERE table_type in (#{types.map{|t| quote(t)}.join(', ')}) and creator NOT IN (0,3,5)"
          select(sql, name).map { |row| row["table_name"] }
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
  "default" AS "default",
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
 INNER JOIN sys.sysUser ON sys.systable.creator = sys.sysuser.user_id AND sys.sysuser.user_name = 'dba'
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

        def set_connection_options
          SA.instance.api.sqlany_execute_immediate(@connection, "SET TEMPORARY OPTION non_keywords = 'LOGIN'") rescue nil
          SA.instance.api.sqlany_execute_immediate(@connection, "SET TEMPORARY OPTION timestamp_format = 'YYYY-MM-DD HH:NN:SS'") rescue nil
          #SA.instance.api.sqlany_execute_immediate(@connection, "SET OPTION reserved_keywords = 'LIMIT'") rescue nil
          # The liveness variable is used a low-cost "no-op" to test liveness
          SA.instance.api.sqlany_execute_immediate(@connection, "CREATE VARIABLE liveness INT") rescue nil
        end
    end
  end
end

