Gem::Specification.new do |s|
  s.name = %q{activerecord-sqlanywhere-adapter}
  s.version = "1.0.1"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = [%q{Eric Farar}]
  s.description = %q{ActiveRecord driver for SQL Anywhere}
  s.email = %q{eric.farrar@ianywhere.com}
  s.files = [
    "CHANGELOG",
    "LICENSE",
    "README",
    "Rakefile",
    "test/connection.rb",
    "lib/active_record/connection_adapters/sqlanywhere_adapter.rb",
    "lib/arel/visitors/sqlanywhere.rb",
    "lib/active_record/connection_adapters/sqlanywhere.rake",
    "lib/activerecord-sqlanywhere-adapter.rb"

  ]
  s.homepage = %q{http://sqlanywhere.rubyforge.org}
  s.licenses = [%q{Apache License Version 2.0}]
  s.require_paths = [%q{lib}]
  s.rubygems_version = %q{>= 1.8.8}
  s.summary = %q{ActiveRecord driver for SQL Anywhere}

  if s.respond_to? :specification_version then
    s.specification_version = 3

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
      s.add_runtime_dependency(%q<sqlanywhere>, [">= 0.1.5"])
      s.add_runtime_dependency(%q<activerecord>, [">= 3.0.3"])
    else
      s.add_dependency(%q<sqlanywhere>, [">= 0.1.5"])
      s.add_dependency(%q<activerecord>, [">= 3.0.3"])
    end
  else
    s.add_dependency(%q<sqlanywhere>, [">= 0.1.5"])
    s.add_dependency(%q<activerecord>, [">= 3.0.3"])
  end
end

