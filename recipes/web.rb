#
# Cookbook Name:: zabbix_lwrp
# Recipe:: web
#
# Copyright (C) LLC 2015-2017 Express 42
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to whom the Software is furnished to do
# so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

extend SELinuxPolicy::Helpers
include_recipe 'selinux_policy::install' if use_selinux

selinux_policy_boolean 'httpd_can_network_connect' do
  value true
end

#For rhel only
case node['platform_family']
when 'rhel', 'fedora'
  include_recipe 'yum-remi-chef::remi-php73'#actual version installed is based on attributes in web.rb
end

include_recipe 'php-fpm'
include_recipe 'chef_nginx::default'

db_vendor = node['zabbix']['server']['database']['vendor']
unless db_vendor == 'postgresql' || db_vendor == 'mysql'
  raise "You should specify correct database vendor attribute node['zabbix']['server']['database']['vendor'] (now: #{node['zabbix']['server']['database']['vendor']})"
end
db_name = 'zabbix'

sql_attr = node['zabbix']['server']['database'][db_vendor]
db_host = sql_attr['configuration']['listen_addresses']
db_port = sql_attr['configuration']['port']

# Get user and database information from data bag

if sql_attr['databag'].nil? ||
   sql_attr['databag'].empty? ||
   get_data_bag(sql_attr['databag']).empty?
  raise "You should specify databag name for zabbix db user in sql_attr['databag'] attibute (now: #{sql_attr['databag']}) and databag should exist"
end

db_user_data = get_data_bag_item(sql_attr['databag'], 'users')['users']
db_user = db_user_data.keys.first
db_pass = db_user_data[db_user]['options']['password']

fastcgi_listen = node['zabbix']['server']['web']['listen']
fastcgi_listen = "unix:#{fastcgi_listen}" if fastcgi_listen[0] == '/'

chef_nginx_site node['zabbix']['server']['web']['server_name'] do
  action :enable
  template 'zabbix-site.conf.erb'
  variables(
    server_name: node['zabbix']['server']['web']['server_name'],
    proxy_listen: node['zabbix']['server']['web']['proxy_listen'],
    fastcgi_listen: fastcgi_listen,
    ssl_ciphers: node['zabbix']['server']['web']['ssl_ciphers'],
    ssl_protocols: node['zabbix']['server']['web']['ssl_protocols']
  )
end

case node['platform_family']
when 'debian'
  packages = []

  if node['platform_version'].to_f < (node['platform'] == 'ubuntu' ? 16.04 : 9)
    php_suffix = '5'
  else
    php_suffix = ''
    packages.concat %w[
      php-mbstring
      php-bcmath
      php-gd
      php-xml
    ]
  end

  case db_vendor
  when 'postgresql'
    packages << "php#{php_suffix}-pgsql"
  when 'mysql'
    packages << "php#{php_suffix}-mysql"
  end

  package packages

  package 'zabbix-frontend-php' do
    response_file 'zabbix-frontend-without-apache.seed'
    action [:install, :reconfig]
  end

when 'rhel'
  case db_vendor
  when 'postgresql'
    package 'zabbix-web-pgsql'
  when 'mysql'
    package 'zabbix-web-mysql'
  end
end

php_fpm_pool 'zabbix' do
  listen_group node['nginx']['group']
  listen node['zabbix']['server']['web']['listen']
  max_children node['zabbix']['server']['web']['max_children']
  max_requests node['zabbix']['server']['web']['max_requests']
  min_spare_servers node['zabbix']['server']['web']['min_spare_servers']
  start_servers node['zabbix']['server']['web']['start_servers']
  max_spare_servers node['zabbix']['server']['web']['max_spare_servers']
  process_manager node['zabbix']['server']['web']['process_manager']
  php_options node['zabbix']['server']['web']['configuration']
end

owner_name = case node['platform_family']
             when 'rhel'
               'apache'
             when 'debian'
               'www-data'
             end

template '/etc/zabbix/web/zabbix.conf.php' do
  source 'zabbix.conf.php.erb'
  mode '0600'
  owner owner_name
  group owner_name
  sensitive true
  variables(
    db_vendor: db_vendor.upcase,
    db_host: db_host,
    db_name: db_name,
    db_port: db_port,
    user_name: db_user,
    user_password: db_pass,
    server_host: 'localhost',
    server_port: '10051'
  )
end
