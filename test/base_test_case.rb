require 'rubygems'
require 'popen4'
require 'tmpdir'
require 'erb'
require 'ftools'
require 'ruby-debug'
require 'test/unit'
require 'em-http'
require 'json'

module BaseTestCase
  def setup
    default_configuration
    @test_config_file = "#{self.method_name}.conf"
    config_test_name = "config_#{self.method_name}"
    self.send(config_test_name) if self.respond_to?(config_test_name)

    unless @disable_start_stop_server
      self.create_config_file
      self.stop_server
      self.start_server
    end
  end

  def teardown
    unless @disable_start_stop_server
      self.stop_server
      self.delete_config_file
    end
  end

  def nginx_executable
    return ENV['NGINX_EXEC'].nil? ? "/usr/local/nginxpushstream/source/nginx-0.7.67/objs/nginx" : ENV['NGINX_EXEC']
  end

  def nginx_address
    return "http://#{nginx_host}:#{nginx_port}"
  end

  def nginx_host
    return ENV['NGINX_HOST'].nil? ? "localhost" : ENV['NGINX_HOST']
  end

  def nginx_port
    return ENV['NGINX_PORT'].nil? ? "9990" : ENV['NGINX_PORT']
  end

  def nginx_workers
    return ENV['NGINX_WORKERS'].nil? ? "1" : ENV['NGINX_WORKERS']
  end

  def start_server
    error_message = ""
    status = POpen4::popen4("#{ nginx_executable } -c #{ Dir.tmpdir }/#{ @test_config_file }") do |stdout, stderr, stdin, pid|
      error_message = stderr.read.strip unless stderr.eof
      return error_message unless error_message.nil?
    end
    assert_equal(0, status.exitstatus, "Server doesn't started - #{error_message}")
  end

  def stop_server
    error_message = ""
    status = POpen4::popen4("#{ nginx_executable } -c #{ Dir.tmpdir }/#{ @test_config_file } -s stop") do |stdout, stderr, stdin, pid|
      error_message = stderr.read.strip unless stderr.eof
      return error_message unless error_message.nil?
    end
    assert_equal(0, status.exitstatus, "Server doesn't stop - #{error_message}")
  end

  def create_config_file
    template = ERB.new @@config_template
    config_content = template.result(binding)
    File.open(Dir.tmpdir + "/#{ @test_config_file }", 'w') {|f| f.write(config_content) }
    File.open(Dir.tmpdir + "/mime.types", 'w') {|f| f.write(@@mime_tipes_template) }
  end

  def delete_config_file
    File.delete(Dir.tmpdir + "/#{ @test_config_file }")
    File.delete(Dir.tmpdir + "/mime.types")
  end

  def time_diff_milli(start, finish)
     (finish - start) * 1000.0
  end

  def time_diff_sec(start, finish)
     (finish - start)
  end

  def fail_if_connecttion_error(client)
    client.errback { |error|
      fail("Erro inexperado na execucao do teste: #{error.last_effective_url.nil? ? "" : error.last_effective_url.request_uri} #{error.response}")
      EventMachine.stop
    }
  end

  def default_configuration
    @max_reserved_memory = '10m'
    @authorized_channels_only = 'off'
    @broadcast_channel_max_qtd = 3
    @broadcast_channel_prefix = 'broad_'
    @content_type = 'text/html; charset=utf-8'
    @header_template = %{<html><head><meta http-equiv=\\"Content-Type\\" content=\\"text/html; charset=utf-8\\">\\r\\n<meta http-equiv=\\"Cache-Control\\" content=\\"no-store\\">\\r\\n<meta http-equiv=\\"Cache-Control\\" content=\\"no-cache\\">\\r\\n<meta http-equiv=\\"Expires\\" content=\\"Thu, 1 Jan 1970 00:00:00 GMT\\">\\r\\n<script type=\\"text/javascript\\">\\r\\nwindow.onError = null;\\r\\ndocument.domain = \\'#{nginx_host}\\';\\r\\nparent.PushStream.register(this);\\r\\n</script>\\r\\n</head>\\r\\n<body onload=\\"try { parent.PushStream.reset(this) } catch (e) {}\\">}
    @max_channel_id_length = 200
    @max_message_buffer_length = 20
    @max_number_of_broadcast_channels = nil
    @max_number_of_channels = nil
    @message_template = %{<script>p(~id~,\\'~channel~\\',\\'~text~\\');</script>}
    @min_message_buffer_timeout = '50m'
    @ping_message_interval = '10s'
    @store_messages = 'on'
    @subscriber_connection_timeout = nil
    @subscriber_disconnect_interval = nil
    @memory_cleanup_timeout = '5m'
  end

  def publish_message(channel, headers, body)
    EventMachine.run {
      pub_1 = EventMachine::HttpRequest.new(nginx_address + '/pub?id=' + channel.to_s).post :head => headers, :body => body, :timeout => 30
      pub_1.callback {
        assert_equal(200, pub_1.response_header.status, "Request was not accepted")
        assert_not_equal(0, pub_1.response_header.content_length, "Empty response was received")
        response = JSON.parse(pub_1.response)
        assert_equal(channel, response["channel"].to_s, "Channel was not recognized")
        EventMachine.stop
      }
      fail_if_connecttion_error(pub_1)
    }
  end

  def create_channel_by_subscribe(channel, headers, timeout=60, &block)
    EventMachine.run {
      sub_1 = EventMachine::HttpRequest.new(nginx_address + '/sub/' + channel.to_s).get :head => headers, :timeout => timeout
      sub_1.stream { |chunk|
        block.call
      }
      sub_1.callback {
        EventMachine.stop
      }
      fail_if_connecttion_error(sub_1)
    }
  end

  @@config_template = %q{
pid                     logs/nginx.pid;
error_log               logs/nginx-main_error.log debug;
# Development Mode
master_process  off;
daemon          off;
worker_processes        <%=nginx_workers%>;

events {
    worker_connections  1024;
    use                 epoll;
}

http {
    include         mime.types;
    default_type    application/octet-stream;

    access_log      logs/nginx-http_access.log;
    error_log       logs/nginx-http_error.log debug;

    tcp_nopush                      on;
    tcp_nodelay                     on;
    keepalive_timeout               10;
    send_timeout                    10;
    client_body_timeout             10;
    client_header_timeout           10;
    sendfile                        on;
    client_header_buffer_size       1k;
    large_client_header_buffers     2 4k;
    client_max_body_size            1k;
    client_body_buffer_size         1k;
    ignore_invalid_headers          on;
    client_body_in_single_buffer    on;
    <%= "push_stream_max_reserved_memory #{@max_reserved_memory};" unless @max_reserved_memory.nil? %>

    server {
        listen          <%=nginx_port%>;
        server_name     <%=nginx_host%>;

        location /channels_stats {
            # activate channels statistics mode for this location
            push_stream_channels_statistics;

            # query string based channel id
            set $push_stream_channel_id             $arg_id;
        }

        location /pub {
            # activate publisher mode for this location
            push_stream_publisher;

            # query string based channel id
            set $push_stream_channel_id             $arg_id;
            # message template
            <%= %{push_stream_message_template "#{@message_template}";} unless @message_template.nil? %>
            # store messages
            <%= "push_stream_store_messages #{@store_messages};" unless @store_messages.nil? %>
            # max messages to store in memory
            <%= "push_stream_max_message_buffer_length #{@max_message_buffer_length};" unless @max_message_buffer_length.nil? %>
            # message ttl
            <%= "push_stream_min_message_buffer_timeout #{@min_message_buffer_timeout};" unless @min_message_buffer_timeout.nil? %>

            <%= "push_stream_max_channel_id_length #{@max_channel_id_length};" unless @max_channel_id_length.nil? %>
            <%= %{push_stream_broadcast_channel_prefix "#{@broadcast_channel_prefix}";} unless @broadcast_channel_prefix.nil? %>
            <%= "push_stream_broadcast_channel_max_qtd #{@broadcast_channel_max_qtd};" unless @broadcast_channel_max_qtd.nil? %>
            <%= "push_stream_max_number_of_channels #{@max_number_of_channels};" unless @max_number_of_channels.nil? %>
            <%= "push_stream_max_number_of_broadcast_channels #{@max_number_of_broadcast_channels};" unless @max_number_of_broadcast_channels.nil? %>

            <%= "push_stream_memory_cleanup_timeout #{@memory_cleanup_timeout};" unless @memory_cleanup_timeout.nil? %>

            # client_max_body_size MUST be equal to client_body_buffer_size or
            # you will be sorry.
            client_max_body_size                    <%= @client_max_body_size.nil? ? '32k' : @client_max_body_size %>;
            client_body_buffer_size                 <%= @client_body_buffer_size.nil? ? '32k' : @client_body_buffer_size %>;
        }

        location ~ /sub/(.*)? {
            # activate subscriber mode for this location
            push_stream_subscriber;

            # positional channel path
            set $push_stream_channels_path          $1;
            <%= "push_stream_max_channel_id_length #{@max_channel_id_length};" unless @max_channel_id_length.nil? %>
            # header to be sent when receiving new subscriber connection
            <%= %{push_stream_header_template "#{@header_template}";} unless @header_template.nil? %>
            # message template
            <%= %{push_stream_message_template "#{@message_template}";} unless @message_template.nil? %>
            # content-type
            <%= %{push_stream_content_type "#{@content_type}";} unless @content_type.nil? %>
            # subscriber may create channels on demand or only authorized
            # (publisher) may do it?
            <%= "push_stream_authorized_channels_only #{@authorized_channels_only};" unless @authorized_channels_only.nil? %>
            # ping frequency
            <%= "push_stream_ping_message_interval #{@ping_message_interval};" unless @ping_message_interval.nil? %>
            # disconnection candidates test frequency
            <%= "push_stream_subscriber_disconnect_interval #{@subscriber_disconnect_interval};" unless @subscriber_disconnect_interval.nil? %>
            # connection ttl to enable recycle
            <%= "push_stream_subscriber_connection_timeout #{@subscriber_connection_timeout};" unless @subscriber_connection_timeout.nil? %>
            <%= %{push_stream_broadcast_channel_prefix "#{@broadcast_channel_prefix}";} unless @broadcast_channel_prefix.nil? %>
            <%= "push_stream_broadcast_channel_max_qtd #{@broadcast_channel_max_qtd};" unless @broadcast_channel_max_qtd.nil? %>

            <%= "push_stream_max_number_of_channels #{@max_number_of_channels};" unless @max_number_of_channels.nil? %>
            <%= "push_stream_max_number_of_broadcast_channels #{@max_number_of_broadcast_channels};" unless @max_number_of_broadcast_channels.nil? %>

            <%= "push_stream_memory_cleanup_timeout #{@memory_cleanup_timeout};" unless @memory_cleanup_timeout.nil? %>


            # solving some leakage problem with persitent connections in
            # Nginx's chunked filter (ngx_http_chunked_filter_module.c)
            chunked_transfer_encoding                   off;
        }
    }
}
  }

  @@mime_tipes_template = %q{
types {
    text/html                             html htm shtml;
    text/css                              css;
    text/xml                              xml;
    image/gif                             gif;
    image/jpeg                            jpeg jpg;
    application/x-javascript              js;
    application/atom+xml                  atom;
    application/rss+xml                   rss;

    text/mathml                           mml;
    text/plain                            txt;
    text/vnd.sun.j2me.app-descriptor      jad;
    text/vnd.wap.wml                      wml;
    text/x-component                      htc;

    image/png                             png;
    image/tiff                            tif tiff;
    image/vnd.wap.wbmp                    wbmp;
    image/x-icon                          ico;
    image/x-jng                           jng;
    image/x-ms-bmp                        bmp;
    image/svg+xml                         svg;

    application/java-archive              jar war ear;
    application/mac-binhex40              hqx;
    application/msword                    doc;
    application/pdf                       pdf;
    application/postscript                ps eps ai;
    application/rtf                       rtf;
    application/vnd.ms-excel              xls;
    application/vnd.ms-powerpoint         ppt;
    application/vnd.wap.wmlc              wmlc;
    application/vnd.wap.xhtml+xml         xhtml;
    application/vnd.google-earth.kml+xml  kml;
    application/vnd.google-earth.kmz      kmz;
    application/x-cocoa                   cco;
    application/x-java-archive-diff       jardiff;
    application/x-java-jnlp-file          jnlp;
    application/x-makeself                run;
    application/x-perl                    pl pm;
    application/x-pilot                   prc pdb;
    application/x-rar-compressed          rar;
    application/x-redhat-package-manager  rpm;
    application/x-sea                     sea;
    application/x-shockwave-flash         swf;
    application/x-stuffit                 sit;
    application/x-tcl                     tcl tk;
    application/x-x509-ca-cert            der pem crt;
    application/x-xpinstall               xpi;
    application/zip                       zip;

    application/octet-stream              bin exe dll;
    application/octet-stream              deb;
    application/octet-stream              dmg;
    application/octet-stream              eot;
    application/octet-stream              iso img;
    application/octet-stream              msi msp msm;

    audio/midi                            mid midi kar;
    audio/mpeg                            mp3;
    audio/x-realaudio                     ra;

    video/3gpp                            3gpp 3gp;
    video/mpeg                            mpeg mpg;
    video/quicktime                       mov;
    video/x-flv                           flv;
    video/x-mng                           mng;
    video/x-ms-asf                        asx asf;
    video/x-ms-wmv                        wmv;
    video/x-msvideo                       avi;
}
  }

end
