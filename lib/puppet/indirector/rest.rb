require 'net/http'
require 'uri'

require 'puppet/network/http_pool'
require 'puppet/network/http/handler'

# Access objects via REST
class Puppet::Indirector::REST < Puppet::Indirector::Terminus
    include Puppet::Network::HTTP::Handler 

    class << self
        attr_reader :server_setting, :port_setting
    end

    # Specify the setting that we should use to get the server name.
    def self.use_server_setting(setting)
        @server_setting = setting
    end

    def self.server
        return Puppet.settings[server_setting || :server]
    end

    # Specify the setting that we should use to get the port.
    def self.use_port_setting(setting)
        @port_setting = setting
    end

    def self.port
        return Puppet.settings[port_setting || :masterport].to_i
    end

    # Figure out the content type, turn that into a format, and use the format
    # to extract the body of the response.
    def deserialize(response, multiple = false)
        case response.code
        when "404"
            return nil
        when /^2/
            unless response['content-type']
                raise "No content type in http response; cannot parse"
            end

            # Convert the response to a deserialized object.
            if multiple
                model.convert_from_multiple(response['content-type'], response.body)
            else
                model.convert_from(response['content-type'], response.body)
            end
        else
            # Raise the http error if we didn't get a 'success' of some kind.
            message = "Server returned %s: %s" % [response.code, response.message]
            raise Net::HTTPError.new(message, response)
        end
    end

    # Provide appropriate headers.
    def headers
        {"Accept" => model.supported_formats.join(", ")}
    end
  
    def network(request)
        Puppet::Network::HttpPool.http_instance(request.server || self.class.server, request.port || self.class.port)
    end

    def find(request)
        p model
        p indirection
        p indirection.model
        deserialize network(request).get(indirection2uri(request), headers)
    end
    
    def search(request)
        unless result = deserialize(network(request).get(indirection2uri(request), headers), true)
            return []
        end
        return result
    end
    
    def destroy(request)
        raise ArgumentError, "DELETE does not accept options" unless request.options.empty?
        deserialize network(request).delete(indirection2uri(request), headers)
    end
    
    def save(request)
        raise ArgumentError, "PUT does not accept options" unless request.options.empty?
        deserialize network(request).put(indirection2uri(request), request.instance.render, headers)
    end

    private

    def environment
        Puppet::Node::Environment.new
    end
end
