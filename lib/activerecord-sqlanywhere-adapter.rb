# https://github.com/rsim/oracle-enhanced/blob/master/lib/activerecord-oracle_enhanced-adapter.rb

if defined?(::Rails::Railtie)

  module ActiveRecord
    module ConnectionAdapters
	  class SqlanywhereRailtie < ::Rails::Railtie
	    rake_tasks do
		  load 'active_record/connection_adapters/sqlanywhere.rake'
		end
		
	  end
	end
  end
  
end