# frozen_string_literal: true

require 'rack'

module Tipi
  module RackAdapter
    class << self
      def run(app)
        ->(req) { respond(req, app.(env(req))) }
      end

      def load(path)
        src = IO.read(path)
        instance_eval(src, path, 1)
      end

      def env(request)
        Qeweney.rack_env_from_request(request)
      end

      def respond(request, (status_code, headers, body))
        headers[':status'] = status_code.to_s

        body = body.instance_variable_get(:@body) if body.is_a? Rack::Deflater::GzipStream

        content =
          if body.respond_to?(:to_path)
            File.open(body.to_path, 'rb') { |f| f.read }
          else
            body.first
          end

        request.respond(content, headers)
      end
    end
  end
end
