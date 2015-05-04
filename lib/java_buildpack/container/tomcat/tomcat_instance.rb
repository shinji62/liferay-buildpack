# Encoding: utf-8
# Cloud Foundry Java Buildpack
# Copyright 2013-2015 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'fileutils'
require 'java_buildpack/component/versioned_dependency_component'
require 'java_buildpack/container'
require 'java_buildpack/container/tomcat/tomcat_utils'
require 'java_buildpack/util/tokenized_version'

module JavaBuildpack
  module Container

    # Encapsulates the detect, compile, and release functionality for the Tomcat instance.
    class TomcatInstance < JavaBuildpack::Component::VersionedDependencyComponent
      include JavaBuildpack::Container

      # Creates an instance
      #
      # @param [Hash] context a collection of utilities used the component
      def initialize(context)
        super(context) { |candidate_version| candidate_version.check_size(3) }
      end

      # (see JavaBuildpack::Component::BaseComponent#compile)
      def compile
        download(@version, @uri) { |file| expand file }

        repackage_portlet_war

        configure_mysql_service

        @droplet.additional_libraries << tomcat_datasource_jar if tomcat_datasource_jar.exist?
        @droplet.additional_libraries.link_to web_inf_lib
      end

      # (see JavaBuildpack::Component::BaseComponent#release)
      def release
      end

      protected

      # (see JavaBuildpack::Component::VersionedDependencyComponent#supports?)
      def supports?
        true
      end

      private

      FILTER = /lf-mysqldb/.freeze

      private_constant :FILTER


      TOMCAT_8 = JavaBuildpack::Util::TokenizedVersion.new('8.0.0').freeze

      private_constant :TOMCAT_8

      def configure_jasper
        return unless @version < TOMCAT_8

        document = read_xml server_xml
        server   = REXML::XPath.match(document, '/Server').first

        listener = REXML::Element.new('Listener')
        listener.add_attribute 'className', 'org.apache.catalina.core.JasperListener'

        server.insert_before '//Service', listener

        write_xml server_xml, document
      end

      def configure_linking
        document = read_xml context_xml
        context  = REXML::XPath.match(document, '/Context').first

        if @version < TOMCAT_8
          context.add_attribute 'allowLinking', true
        else
          context.add_element 'Resources', 'allowLinking' => true
        end

        write_xml context_xml, document
      end

      def expand(file)
        with_timing "Expanding Tomcat to #{@droplet.sandbox.relative_path_from(@droplet.root)}" do
          FileUtils.mkdir_p @droplet.sandbox
          shell "tar xzf #{file.path} -C #{@droplet.sandbox} --strip 1  2>&1"

          @droplet.copy_resources
          configure_linking
          configure_jasper
        end
      end

      def root
        tomcat_webapps + 'ROOT'
      end

      def tomcat_datasource_jar
        tomcat_lib + 'tomcat-jdbc.jar'
      end

      def web_inf_lib
        @droplet.root + 'WEB-INF/lib'
      end


       # The war is presented to the buildpack exploded, so we need to repackage it in a war
      def repackage_portlet_war

        destination = "#{@droplet.sandbox}" + "/deploy/#{@application.details['application_name']}"+ '.war'
        with_timing "Packaging #{@application.root} to #{destination} " do

          FileUtils.mkdir_p "#{@droplet.sandbox}/deploy"
          shell "zip -r #{destination}   #{@application.root}  -x '.*' -x '*/.*' "
        end
      end

      # In this method we check if the application is bound to a service. If that is the case then we create the portal-ext.properties
      # and store it in Liferay Portal classes directory.

      def configure_mysql_service

          @logger       = JavaBuildpack::Logging::LoggerFactory.instance.get_logger TomcatInstance
          service       = @application.services.find_service FILTER

          @logger.info{ "--->Application seems to be bound to a lf-mysqldb service" }

          if service.to_s ==''
            @logger.warn{'--->No lf-mysqldb SERVICE FOUND'}
          else
              @logger.info{ "--->Configuring MySQL Store for Liferay" }

              file = "#{@droplet.sandbox}/webapps/ROOT/WEB-INF/classes/portal-ext.properties"

              if File.exist? (file)
                  @logger.info {"--->Portal-ext.properties file already exist, so skipping MySQL configuration" }
              else
                  with_timing "Creating portal-ext.properties in #{file}" do

                      credentials   = service['credentials']

                      @logger.debug{ "--->credentials:#{credentials} found" }

                      jdbc_url_name = credentials['jdbcUrl']
                      host_name     = credentials['hostname']
                      username      = credentials['username']
                      password      = credentials['password']

                      @logger.info {"--->  jdbc_url_name:  #{jdbc_url_name} \n"}
                      @logger.info {"--->  username:  #{username} \n"}
                      @logger.info {"--->  password:  #{password} \n"}
                      @logger.info {"--->  host_name:  #{host_name} \n"}


                      File.open(file, 'w') do  |file| 
                        file.puts("#\n")
                        file.puts("# MySQL\n")
                        file.puts("#\n")

                        file.puts("jdbc.default.driverClassName=com.mysql.jdbc.Driver\n")
                        file.puts("jdbc.default.url=" + jdbc_url_name + "\n")
                        file.puts("jdbc.default.username=" + username + "\n")
                        file.puts("jdbc.default.password=" + password + "\n")

                        file.puts("#\n")
                        file.puts("# Configuration Connextion Pool\n") # This should be configurable through ENV
                        file.puts("#\n")

                        file.puts("jdbc.default.acquireIncrement=5\n")
                        file.puts("jdbc.default.connectionCustomizerClassName=com.liferay.portal.dao.jdbc.pool.c3p0.PortalConnectionCustomizer\n")
                        file.puts("jdbc.default.idleConnectionTestPeriod=60\n")
                        file.puts("jdbc.default.maxIdleTime=3600\n")
                        file.puts("jdbc.default.maxPoolSize=20\n")
                        file.puts("jdbc.default.minPoolSize=10\n")
                        file.puts("jdbc.default.numHelperThreads=3\n")

                        file.puts("#\n")
                        file.puts("# Configuration of the auto deploy folder\n")
                        file.puts("#\n")

                        file.puts("auto.deploy.dest.dir=${catalina.home}/deploy\n")
                        file.puts("auto.deploy.dir=${catalina.home}/deploy\n")
                        file.puts("auto.deploy.deploy.dir=${catalina.home}/deploy\n")

                      end

                  end # end with_timing
              end
        end # End else
      end # End def

    end

  end
end
