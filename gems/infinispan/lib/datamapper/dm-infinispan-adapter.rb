#
# Copyright 2011 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
require "digest/sha1"
require 'dm-core'
require 'cache'
require 'json'
require 'datamapper/model'

module DataMapper::Adapters

  class InfinispanAdapter < AbstractAdapter

    DataMapper::Model.append_inclusions( Infinispan::Model )

    def initialize( name, options )
      super
      @options            = options.dup
      @metadata           = @options.dup
      @options[:name]     = name.to_s
      @options[:index]    = true
      @metadata[:name]    = name.to_s + "/metadata"
      @cache              = TorqueBox::Infinispan::Cache.new( @options )
      @metadata_cache     = TorqueBox::Infinispan::Cache.new( @metadata )
    end


    def create( resources )
      cache.transaction do
        resources.each do |resource|
          initialize_serial( resource, @metadata_cache.increment( index_for( resource ) ) )
          cache.put( key( resource ), serialize( resource ) )
        end
      end
    end

    def read( query )
      records = []
      cache.transaction { records = search( query ) }
      query.filter_records(records)
    end

    def update( attributes, collection )
      cache.transaction do
        attributes = attributes_as_fields(attributes)
        collection.each do |resource|
          resource.attributes(:field).merge(attributes)
          cache.put( key(resource), serialize(resource) )
        end
      end
    end

    def delete( collection )
      cache.transaction do
        collection.each do |resource|
          cache.remove( key(resource) )
        end
      end
    end

    def stop
      cache.stop
    end

    private
    def search_manager
      @search_manager ||= cache.search_manager
    end

    def search( query )
      #builder = search_manager.build_query_builder_for_class( query.model.java_class ).get
      #cache_query = search_manager.get_query( builder.all.create_query, query.model.java_class )
      cache_query = search_manager.get_query( build_query( query ), query.model.java_class )
      cache_query.list.collect { |record| deserialize(record) }
    end

    def build_query( query )
      #puts query.conditions.inspect

      builder = search_manager.build_query_builder_for_class( query.model.java_class ).get
      return builder.all.create_query if query.conditions.nil?

      condition = query.conditions.first

      #query.conditions.each do |condition|
        puts "CONDITION: #{condition.inspect}"
        puts "CONDITION CLASS: #{condition.class}"
        puts "CONDITION OPERANDS: #{condition.operands.inspect}" if condition.respond_to? :operands
        #puts "CONDITION VALUE: #{condition.value}"
        #puts "CONDITION SUBJECT: #{condition.subject.name}"
        if condition.class == DataMapper::Query::Conditions::NotOperation
          if condition.operands.first.class == DataMapper::Query::Conditions::EqualToComparison
            field = condition.operands.first.subject.name
            # Not nil means find everything that isn't nill
            if condition.operands.first.value.nil?
              handle_equal_to( builder, field, '?*' )
            else
              builder.bool.must( handle_equal_to( builder, field, condition.operands.first.value ) ).not.create_query
            end
          else
            builder.all.create_query
          end
        elsif condition.class == DataMapper::Query::Conditions::EqualToComparison
          handle_equal_to( builder, condition.subject.name, condition.value.to_s )
        else
          builder.all.create_query
        end
      #end
    end

    def handle_equal_to( builder, field, value )
      if value.include?( '?' ) || value.include?( '*' )
        builder.keyword.wildcard.on_field(field).matching(value.to_s).create_query
      else
        builder.keyword.on_field(field).matching(value.to_s).create_query
      end
    end

    def cache
      @cache
    end

    def metadata_cache
      @metadata_cache
    end

    def next_id(resource)
      Digest::SHA1.hexdigest(Time.now.to_i + rand(1000000000).to_s)[1..length].to_i
    end

    def key( resource )
      model = resource.model
      key = resource.key.nil? ? '' : resource.key.join('/')
      "#{model}/#{key}/#{resource.id}"
    end      
    
    def serialize(resource)
      resource.is_a?(DataMapper::Resource) ? resource : resource.to_json
    end

    def deserialize(value)
      value.is_a?(String) ? JSON.parse(value) : value
    end

    def index_for( resource )
      resource.model.name + ".index"
    end

    def all_records
      records = []
      cache.keys.each do |key|
        value = cache.get(key)
        records << deserialize(value) if value
      end
      records
    end

  end
end
