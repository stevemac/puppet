require 'puppet/rails/resource'
require 'puppet/rails/fact_name'
require 'puppet/rails/source_file'
require 'puppet/util/rails/collection_merger'

Puppet::TIME_DEBUG = true

class Puppet::Rails::Host < ActiveRecord::Base
    include Puppet::Util
    include Puppet::Util::CollectionMerger

    has_many :fact_values, :dependent => :destroy
    has_many :fact_names, :through => :fact_values
    belongs_to :source_file
    has_many :resources, :dependent => :destroy

    # If the host already exists, get rid of its objects
    def self.clean(host)
        if obj = self.find_by_name(host)
            obj.rails_objects.clear
            return obj
        else
            return nil
        end
    end

    # Store our host in the database.
    def self.store(node, resources)
        args = {}

        host = nil
        transaction do
            #unless host = find_by_name(name)
            seconds = Benchmark.realtime {
                unless host = find_by_name(node.name)
                    host = new(:name => node.name)
                end
            }
            Puppet.notice("Searched for host in %0.2f seconds" % seconds) if defined?(Puppet::TIME_DEBUG)
            if ip = node.parameters["ipaddress"]
                host.ip = ip
            end

            if env = node.environment
                host.environment = env
            end

            # Store the facts into the database.
            host.setfacts node.parameters

            seconds = Benchmark.realtime {
                host.setresources(resources)
            }
            Puppet.notice("Handled resources in %0.2f seconds" % seconds) if defined?(Puppet::TIME_DEBUG)

            host.last_compile = Time.now

            host.save
        end

        return host
    end

    # Return the value of a fact.
    def fact(name)
        if fv = self.fact_values.find(:all, :include => :fact_name,
                                      :conditions => "fact_names.name = '#{name}'") 
            return fv
        else
            return nil
        end
    end
    
    # returns a hash of fact_names.name => [ fact_values ] for this host.
    def get_facts_hash
        fact_values = self.fact_values.find(:all, :include => :fact_name)
        return fact_values.inject({}) do | hash, value |
            hash[value.fact_name.name] ||= []
            hash[value.fact_name.name] << value
            hash
        end
    end
    

    def setfacts(facts)
        facts = facts.dup
        
        ar_hash_merge(get_facts_hash(), facts, 
                      :create => Proc.new { |name, values|
                          fact_name = Puppet::Rails::FactName.find_or_create_by_name(name)
                          values = [values] unless values.is_a?(Array)
                          values.each do |value|
                              fact_values.build(:value => value,
                                                :fact_name => fact_name)
                          end
                      }, :delete => Proc.new { |values|
                          values.each { |value| self.fact_values.delete(value) }
                      }, :modify => Proc.new { |db, mem|
                          mem = [mem].flatten
                          fact_name = db[0].fact_name
                          db_values = db.collect { |fact_value| fact_value.value }
                          (db_values - (db_values & mem)).each do |value|
                              db.find_all { |fact_value| 
                                  fact_value.value == value 
                              }.each { |fact_value|
                                  fact_values.delete(fact_value)
                              }
                          end
                          (mem - (db_values & mem)).each do |value|
                              fact_values.build(:value => value, 
                                                :fact_name => fact_name)
                          end
                      })
    end

    # Set our resources.
    def setresources(list)
        existing = nil
        seconds = Benchmark.realtime {
            existing = find_resources()
        }
        Puppet.notice("Searched for resources in %0.2f seconds" % seconds) if defined?(Puppet::TIME_DEBUG)

        seconds = Benchmark.realtime {
            find_resources_parameters_tags(existing)
        } if id
        Puppet.notice("Searched for resource params and tags in %0.2f seconds" % seconds) if defined?(Puppet::TIME_DEBUG)

        seconds = Benchmark.realtime {
            compare_to_catalog(existing, list)
        }
        Puppet.notice("Resource comparison took %0.2f seconds" % seconds) if defined?(Puppet::TIME_DEBUG)
    end

    def find_resources
        resources.find(:all, :include => :source_file).inject({}) do | hash, resource |
            hash[resource.ref] = resource
            hash
        end
    end

    def find_resources_parameters_tags(resources)
        # initialize all resource parameters
        resources.each do |key,resource|
            resource.params_hash = []
        end

        resources_by_id = resources.inject({}) do |hash, res|
            hash[res[1]['id']] = res[1]
            hash
        end

        find_resources_parameters(resources_by_id)
        find_resources_tags(resources_by_id)
    end

    def compare_to_catalog(resources, list)
        compiled = list.inject({}) do |hash, resource|
            hash[resource.ref] = resource
            hash
        end
        ar_hash_merge(resources, compiled,
                      :create => Proc.new { |ref, resource|
                          resource.to_rails(self)
                      }, :delete => Proc.new { |resource|
                          self.resources.delete(resource)
                      }, :modify => Proc.new { |db, mem|
                          mem.modify_rails(db)
                      })
    end

    def find_resources_parameters(resources)
        params = Puppet::Rails::ParamValue.find_all_params_from_host(self)

        # assign each loaded parameters/tags to the resource it belongs to
        params.each do |param|
            resources[param['resource_id']].add_param_to_hash(param)
        end
    end

    def find_resources_tags(resources)
        tags = Puppet::Rails::ResourceTag.find_all_tags_from_host(self)

        tags.each do |tag|
            resources[tag['resource_id']].add_tag_to_hash(tag)
        end
    end

    def update_connect_time
        self.last_connect = Time.now
        save
    end
end

