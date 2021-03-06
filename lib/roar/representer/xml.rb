require "active_support/core_ext/hash/conversions"
require "hooks"

# DISCUSS: is it sufficient to include only one concrete Representer module per model instance? Why would you need more than one? 
module Roar
  module Representer
    module Xml  # DISCUSS: this is a serialization backend for ActiveSupport xml serializer.
      extend ActiveSupport::Concern
      
      included do
        extend Hooks::InheritableAttribute
        inheritable_attr :xml_collections
        self.xml_collections = {}
        inheritable_attr :xml_typed_entities
        self.xml_typed_entities = {}
      end
      
      # DISCUSS: make as many method as possible abstract so other representers can use it as well.
      # TODO: rename this module to Representer::Xml::ConfigurationDsl
      # job: writing configuration to @_represents[:xml]
      module XmlDsl
        def xml(*args, &block)
          # TODO: save block.
          instance_exec(&block)
        end
        
        def has_many(name, options={})
          xml_collections[name] = options
        end
        alias_method :collection, :has_many
        
        def has_one(name, options={})
          xml_typed_entities[name] = options
        end
        
        def has_proxied(name, options={})
          has_one(name, {:class => EntityProxy.class_for(options)}) 
        end
        
        def has_many_proxied(name, options={})
          has_many(name, {:class => EntityProxy.class_for(options)}) 
        end
      end
      
      
      module ClassMethods
        include XmlDsl
        
        # Deserializes the xml document and creates a new model instance with the parsed attribute hash.
        def from_body(xml)
          deserialized_hash = Hash.from_xml(xml)  # yes, we use ActiveSupport for the real work. #DISCUSS: move to backend-specific method .from_xml_string ?
          attributes = deserialized_hash[model_name]
          
          from_xml_attributes(attributes)
        end
        alias_method :from_xml, :from_body # convenience alias, not mandatory.
        
        # Backend-specific: Receives hash parsed from <tt>Hash.from_xml</tt> and prepares the abstract hash.
        def from_xml_attributes(attributes)
          # DISCUSS: use a hook here for collections and entity?
          # DISCUSS: maybe we shouldn't distinguish between collections and entities, maybe there should be builders that know what to do. don't wanna overengineer here.
          create_collection_attributes_from_xml(attributes)
          create_typed_attributes_from_xml(attributes)
          
          from_attributes(attributes) # generic hash.
        end
        
        # Generic creator. # FIXME: move to Representer base.
        # DISCUSS: semantically identical to #update_attributes
        def from_attributes(attributes)
          new(attributes)
        end
        
        
        def create_collection_attributes_for_xml(attributes)
          filter_attributes_for(attributes, xml_collections) do |name, options|
            collection = attributes.delete(name)
            attributes[name.singularize] = UnwrappedCollection.new(collection)
          end
        end
        
        def create_typed_attribute_for_xml(attributes)
          filter_attributes_for(attributes, xml_typed_entities) do |name, options|
            ent = attributes.delete(name)
            attributes[name] = ent.to("application/xml")  # FIXME: representation format from @mime_type.
          end
        end
      
      protected
        # Since Hash.from_xml doesn't always detect collections we do it here. 
        def create_collection_attributes_from_xml(attributes)
          filter_attributes_for(attributes, xml_collections) do |name, options|
            collection  = attributes.delete(name.singularize) || []
            collection  = [collection] unless collection.kind_of?(Array) 
            collection  = typecast_collection_for(collection, options[:class]) if options[:class]
            
            attributes[name] = collection
          end
        end
        
        def typecast_collection_for(collection, klass)
          collection.collect { |e| klass.from_xml_attributes(e) }
        end
        
        # Attributes can be typecasted with +has_one+.
        def create_typed_attributes_from_xml(attributes)
          filter_attributes_for(attributes, xml_typed_entities) do |name, options|
            item  = attributes.delete(name)                        # attributes[:sum]
            item  = options[:class].from_xml_attributes(item) # Sum.from_xml_attributes
            # DISCUSS: we could also run a hook here.
            attributes[name] = item
          end
        end
        
        def filter_attributes_for(attributes, config)
          config.each do |name, options|
            name = name.to_s
            yield name, options
          end
        end
      end
      
      
      
      def to_xml(options={})  # DISCUSS: shouldn't be overwritten.... this is backend-specific (Hash#to_xml vs. some builder whatever).
        xml_attributes = attributes_for_xml
        
        # from here is render-only:
        options.reverse_merge!  :root => self.class.model_name, # FIXME: second dependency (we know something about the subject)
                                :skip_instruct => true,
                                :skip_types   => true
        
        xml_attributes.to_xml(options)  # let Hash#to_xml do the actual rendering.
      end
      
      # Backend-specific: Returns hash ready for xml rendering by <tt>Hash#to_xml</tt>
      def attributes_for_xml(*)
        serialized = attributes.dup # FIXME: we don't want to override attributes here.
        self.class.create_collection_attributes_for_xml(serialized)
        serialized
      end
      
      
      # For item collections that shouldn't be wrapped with a container tag.
      class UnwrappedCollection < Array
        def to_xml(*args)
          each do |e|
            # DISCUSS: we should call #to_tag here.
            e.to_xml(*args) # pass options[:builder] to Hash or whatever. don't like that.
          end
        end
      end
    end
    
    class XmlRepresenter
      include Xml
      
      module ConfigurationDsl
        def has_many(name, options={})
          xml_collections[name] = options
        end
        alias_method :collection, :has_many
        
        def has_one(name, options={})
          xml_typed_entities[name] = options
        end
        
        def has_proxied(name, options={})
          has_one(name, {:class => EntityProxy.class_for(options)}) 
        end
        
        def has_many_proxied(name, options={})
          has_many(name, {:class => EntityProxy.class_for(options)}) 
        end
      end
      
      include ConfigurationDsl
      # FIXME: use one variable?
      extend Hooks::InheritableAttribute
      inheritable_attr :xml_collections
      self.xml_collections = {}
      inheritable_attr :xml_typed_entities
      self.xml_typed_entities = {}
        
      
      def serialize(model_name, attributes, options={})
        xml_attributes = serializable_hash_for(attributes)
        
        # from here is render-only:
        options.reverse_merge!  :root => model_name,
                                :skip_instruct => true,
                                :skip_types   => true
        
        xml_attributes.to_xml(options)  # let Hash#to_xml do the actual rendering.
      end
      
      # Backend-specific: Returns hash ready for xml rendering by <tt>Hash#to_xml</tt>
      def serializable_hash_for(attributes)
        serialized = attributes.dup # FIXME: we don't want to override attributes here.
        create_collection_attributes_for_xml(serialized)
        create_typed_attributes_for_xml(serialized)
        serialized
      end
      
      
      
      
      def deserialize(model_name, xml)
        deserialized_hash = Hash.from_xml(xml)  # yes, we use ActiveSupport for the real work. #DISCUSS: move to backend-specific method .from_xml_string ?
        attributes = deserialized_hash[model_name]
        
        from_xml_attributes(attributes)
      end
      
      
    # Backend-specific: Receives hash parsed from <tt>Hash.from_xml</tt> and prepares the abstract hash.
      def from_xml_attributes(attributes)
        # DISCUSS: use a hook here for collections and entity?
        # DISCUSS: maybe we shouldn't distinguish between collections and entities, maybe there should be builders that know what to do. don't wanna overengineer here.
        create_collection_attributes_from_xml(attributes)
        create_typed_attributes_from_xml(attributes)
        
        attributes # generic hash.
      end
      
       def create_collection_attributes_for_xml(attributes)
          filter_attributes_for(attributes, self.class.xml_collections) do |name, options|
            collection = attributes.delete(name)
            attributes[name.singularize] = UnwrappedCollection.new(collection)
          end
        end
        
        def create_typed_attributes_for_xml(attributes)
          filter_attributes_for(attributes, self.class.xml_typed_entities) do |name, options|
            ent = attributes.delete(name)
            attributes[name] = ent.to("application/xml")  # FIXME: representation format from @mime_type.
          end
        end
      
        # Since Hash.from_xml doesn't always detect collections we do it here. 
        def create_collection_attributes_from_xml(attributes)
          filter_attributes_for(attributes, self.class.xml_collections) do |name, options|
            collection  = attributes.delete(name.singularize) || []
            collection  = [collection] unless collection.kind_of?(Array) 
            collection  = typecast_collection_for(collection, options[:class]) if options[:class]
            
            attributes[name] = collection
          end
        end
        
        def typecast_collection_for(collection, klass)
          collection.collect { |e| klass.from_xml_attributes(e) }
        end
        
        # Attributes can be typecasted with +has_one+.
        def create_typed_attributes_from_xml(attributes)
          filter_attributes_for(attributes, self.class.xml_typed_entities) do |name, options|
            item  = attributes.delete(name)                        # attributes[:sum]
            item  = options[:class].from_xml_attributes(item) # Sum.from_xml_attributes
            # DISCUSS: we could also run a hook here.
            attributes[name] = item
          end
        end
        
        def filter_attributes_for(attributes, config)
          config.each do |name, options|
            name = name.to_s
            yield name, options
          end
        end
    end
  end
end
