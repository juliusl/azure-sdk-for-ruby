#-------------------------------------------------------------------------
# Copyright 2013 Microsoft Open Technologies, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#--------------------------------------------------------------------------

require 'azure/base_management/serialization'
require 'azure/base_management/location'
require 'azure/base_management/affinity_group'

module Azure
  module BaseManagement
    class BaseManagementService
      def initialize
        validate_configuration
        cert_file = Azure.config.management_certificate
        cert_file = read_cert_from_file(cert_file) if File.file?(cert_file)

        begin
          if cert_file =~ /-----BEGIN CERTIFICATE-----/
            certificate_key = OpenSSL::X509::Certificate.new(cert_file)
            private_key = OpenSSL::PKey::RSA.new(cert_file)
          else
          # Parse pfx content
            cert_content = OpenSSL::PKCS12.new(cert_file)
            certificate_key = OpenSSL::X509::Certificate.new(
              cert_content.certificate.to_pem
            )
            private_key = OpenSSL::PKey::RSA.new(cert_content.key.to_pem)
          end
        rescue OpenSSL::OpenSSLError => e
          raise "Management certificate not valid. Error: #{e.message}"
        end

        Azure.configure do |config|
          config.http_certificate_key = certificate_key
          config.http_private_key = private_key
        end
      end

      def validate_configuration
        subs_id = Azure.config.subscription_id
        error_message = 'Subscription ID not valid.'
        raise error_message if subs_id.nil? || subs_id.empty?

        m_ep = Azure.config.management_endpoint
        error_message = 'Management endpoint not valid.'
        raise error_message if m_ep.nil? || m_ep.empty?

        m_cert = Azure.config.management_certificate
        if File.file?(m_cert) && File.extname(m_cert).downcase =~ /(pem|pfx)$/ # validate only if input is file path
          error_message = "Could not read from file '#{m_cert}'."
          raise error_message unless test('r', m_cert)
        end
      end

      # Public: Gets a list of regional data center locations from the server
      #
      # Returns an array of Azure::BaseManagement::Location objects
      def list_locations
        request = Azure::BaseManagement::ManagementHttpRequest.new(:get, '/locations')
        response = request.call
        Serialization.locations_from_xml(response)
      end

      # Public: Gets a list of role sizes associated with the
      # specified subscription.
      #
      # Returns an array of String values for role sizes
      def list_role_sizes
        role_sizes = []
        locations = list_locations
        locations.each do | location |
         role_sizes << location.role_sizes
        end
        role_sizes.flatten.uniq.compact.sort
      end

      # Public: Gets a lists the affinity groups associated with
      # the specified subscription.
      #
      # See http://msdn.microsoft.com/en-us/library/azure/ee460797.aspx
      #
      # Returns an array of Azure::BaseManagement::AffinityGroup objects
      def list_affinity_groups
        request_path = '/affinitygroups'
        request = Azure::BaseManagement::ManagementHttpRequest.new(:get, request_path, nil)
        response = request.call
        Serialization.affinity_groups_from_xml(response)
      end

      # Public: Creates a new affinity group for the specified subscription.
      #
      # ==== Attributes
      #
      # * +name+           - String. Affinity Group name.
      # * +location+       - String. The location where the affinity group will
      # be created.
      # * +label+         - String. Name for the affinity specified as a
      # base-64 encoded string.
      #
      # ==== Options
      #
      # Accepted key/value pairs are:
      # * +:description+   - String. A description for the affinity group.
      # (optional)
      #
      # See http://msdn.microsoft.com/en-us/library/azure/gg715317.aspx
      #
      # Returns:  None
      def create_affinity_group(name, location, label, options = {})
        if name.nil? || name.strip.empty?
          raise 'Affinity Group name cannot be empty'
        elsif list_affinity_groups.map(&:name).include?(name)
          raise Azure::Error::Error.new(
            'ConflictError',
            409,
            "An affinity group #{name}"\
            " already exists in the current subscription."
          )
        else
          validate_location(location)
          body = Serialization.affinity_group_to_xml(name,
                                                     location,
                                                     label,
                                                     options)
          request_path = '/affinitygroups'
          request = Azure::BaseManagement::ManagementHttpRequest.new(:post, request_path, body)
          request.call
          Azure::Loggerx.info "Affinity Group #{name} is created."
        end
      end

      # Public: updates the label and/or the description for an affinity group
      # for the specified subscription.
      #
      # ==== Attributes
      #
      # * +name+          - String. Affinity Group name.
      # * +label+         - String. Name for the affinity specified as a
      # base-64 encoded string.
      #
      # ==== Options
      #
      # Accepted key/value pairs are:
      # * +:description+   - String. A description for the affinity group.
      # (optional)
      #
      # See http://msdn.microsoft.com/en-us/library/azure/gg715316.aspx
      #
      # Returns:  None
      def update_affinity_group(name, label, options = {})
        raise 'Label name cannot be empty' if label.nil? || label.empty?
        if affinity_group(name)
          body = Serialization.resource_to_xml(label, options)
          request_path = "/affinitygroups/#{name}"
          request = Azure::BaseManagement::ManagementHttpRequest.new(:put, request_path, body)
          request.call
          Azure::Loggerx.info "Affinity Group #{name} is updated."
        end
      end

      # Public: Deletes an affinity group in the specified subscription
      #
      # ==== Attributes
      #
      # * +name+       - String. Affinity Group name.
      #
      # See http://msdn.microsoft.com/en-us/library/azure/gg715314.aspx
      #
      # Returns:  None
      def delete_affinity_group(name)
        if affinity_group(name)
          request_path = "/affinitygroups/#{name}"
          request = Azure::BaseManagement::ManagementHttpRequest.new(:delete, request_path)
          request.call
          Azure::Loggerx.info "Deleted affinity group #{name}."
        end
      end

      # Public: returns the system properties associated with the specified
      # affinity group.
      #
      # ==== Attributes
      #
      # * +name+       - String. Affinity Group name.
      #
      # See http://msdn.microsoft.com/en-us/library/azure/ee460789.aspx
      #
      # Returns:  Azure::BaseManagement::AffinityGroup object
      def get_affinity_group(name)
        if affinity_group(name)
          request_path = "/affinitygroups/#{name}"
          request = Azure::BaseManagement::ManagementHttpRequest.new(:get, request_path)
          response = request.call
          Serialization.affinity_group_from_xml(response)
        end
      end

      private
      def read_cert_from_file(cert_file_path)
        if File.extname(cert_file_path).downcase == '.pem'
          File.read(cert_file_path)
        else
          File.binread(cert_file_path)
        end
      end

      def affinity_group(affinity_group_name)
        if affinity_group_name.nil? ||\
           affinity_group_name.empty? ||\
           !list_affinity_groups.map { |x| x.name.downcase }.include?(
            affinity_group_name.downcase
           )
          error = Azure::Error::Error.new('AffinityGroupNotFound',
                                          404,
                                          'The affinity group does not exist.')
          raise error
        else
          true
        end
      end

      def validate_location(location_name)
        base_mgmt_service = Azure::BaseManagementService.new
        locations = base_mgmt_service.list_locations.map(&:name)
        unless locations.map(&:downcase).include?(location_name.downcase)
          error = "Value '#{location_name}' specified for parameter"\
                  " 'location' is invalid."\
                  " Allowed values are #{locations.join(',')}"
          raise error
        end
      end
    end
  end
end
