# Taken from https://github.com/rsim/oracle-enhanced/blob/master/lib/active_record/connection_adapters/oracle_enhanced.rake

# implementation idea taken from JDBC adapter
# added possibility to execute previously defined task (passed as argument to task block)
def redefine_task(*args, &block)
  task_name = Hash === args.first ? args.first.keys[0] : args.first
  existing_task = Rake.application.lookup task_name
  existing_actions = nil
  if existing_task
    class << existing_task; public :instance_variable_set, :instance_variable_get; end
      existing_task.instance_variable_set "@prerequisites", FileList[]
      existing_actions = existing_task.instance_variable_get "@actions"
      existing_task.instance_variable_set "@actions", []
    end
    task(*args) do
      block.call(existing_actions)
    end
  end


# https://github.com/rsim/oracle-enhanced/blob/master/lib/active_record/connection_adapters/oracle_enhanced.rake

if defined?(drop_database) == 'method'
  def drop_database_with_sqlanywhere(config)
    if config['adapter'] == 'sqlanywhere'
      ActiveRecord::Base.establish_connection(config)
      ActiveRecord::Base.connection.purge_database
    else
      drop_database_without_sqlanywhere(config)
    end
  end
  alias :drop_database_without_sqlanywhere :drop_database
  alias :drop_database :drop_database_with_sqlanywhere
end

namespace :db do
  namespace :test do
    redefine_task :purge => :environment do |existing_actions|
      abcs = ActiveRecord::Base.configurations
      if abcs['test']['adapter'] == 'sqlanywhere'
        ActiveRecord::Base.establish_connection(:test)
        ActiveRecord::Base.connection.purge_database
      else
        Array(existing_actions).each{|action| action.call}
      end
    end
  end
end