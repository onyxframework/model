module Core::Schema
  # Declare schema attribute or reference, it must be called within the `.schema` block:
  #
  # ```
  # class User
  #   include Core::Schema
  #
  #   schema users do
  #     type id : Int32 = DB::Default, primary_key: true   # It's the *primary key*
  #     type name : String                                 # It's a mandatory attribute
  #     type age : Union(Int32 | Nil)                      # It's a nilable attribute
  #     type posts : Array(Post), foreign_key: "author_id" # It's an *implicit foreign reference*
  #   end
  # end
  #
  # class Post
  #   include Core::Schema
  #
  #   schema posts do
  #     type id : Int32 = DB::Default, primary_key: true # It's the *primary key*
  #     type author : User, key: "author_id"             # It's a mandatory *explicit direct reference*
  #     type content : String                            # It's a mandatory attribute
  #     type created_at : Time = DB::Default             # It's an attribute with default value set on DB side
  #     type updated_at : Union(Time | Nil)              # It's a nilable attribute
  #   end
  # end
  # ```
  #
  # Basically, `.type` mirrors the table column. It can be any Crystal type as long as it's an another `Schema` or has `#to_db` method defined. Also special `Union(Type | Nil)` is supported to mark the attribute as nilable.
  #
  # Supported *options*:
  #
  # - `primary_key` - whether is this type a primary key. There must be exactly **one** primary key for a single schema
  # - `key` - table key for this type *if it differs from the name*, e.g. `type encrypted_password : String, key: "password"`. If it's present for a reference, the type is considered *direct reference*
  # - `foreign_key` - foreign table key for this type, e.g. `type posts : Array(Post), foreign_key: "author_id"`. If it's present, the type is treated as *foreign reference*
  macro type(declaration, **options)
    {%
      raise "A schema cannot contain multiple primary keys" if CORE_ATTRIBUTES.find(&.["primary_key"]) && options["primary_key"]

      unless declaration.is_a?(TypeDeclaration)
        raise "Invalid schema type declaration syntax. The valid one is 'type name : Type( = default)', e.g. 'type id : Int32 = rand(100)'"
      end

      enumerable = false
      reference = nil

      if (type = declaration.type.resolve).union?
        unless type.union_types.size == 2 && type.nilable?
          raise "Only two-sized Unions with Nil (e.g. 'Int32 | Nil') are allowed on Schema attribute definition. Given: '#{declaration.type.resolve}'"
        end

        type = type.union_types.find { |t| t != Nil }

        if type < Core::Schema
          reference = type
        elsif type < Enumerable
          enumerable = type.name

          # Reference is resolved only if it is the only Enumerable type var
          # E.g. `Array(User)` would be treated as reference, but `Hash(User, Int32)` would not
          if (type.type_vars.size == 1 && (type = type.type_vars.first) < Core::Schema)
            reference = type
          end
        end
      else
        if (type = declaration.type.resolve) < Core::Schema
          reference = type
        elsif (enu = declaration.type.resolve) < Enumerable
          enumerable = declaration.type.name

          # Reference is resolved only if it is the only Enumerable type var
          # E.g. `Array(User)` would be treated as reference, but `Hash(User, Int32)` would not
          if (enu.type_vars.size == 1 && (type = enu.type_vars.first) < Core::Schema)
            reference = type
          end
        end
      end

      raise "A reference attribute cannot be a primary key" if reference && options["primary_key"]
      raise "An enumerable attribute cannot be a primary key" if enumerable && options["primary_key"]

      db_nilable = declaration.type.resolve.union? && declaration.type.resolve.nilable?
      db_default = declaration.value && declaration.value.resolve == DB::Default
      default_instance_value = (declaration.value unless db_default) || nil
      key = options["key"] || (declaration.var.stringify unless options["foreign_key"])
    %}

    getter {{declaration.var}} : {{declaration.type}} | Nil = {{default_instance_value}}

    {% if reference && options["foreign_key"] %}
      property {{declaration.var}} : {{declaration.type}} | Nil = {{default_instance_value}}
    {% end %}

    {% if key %}
      # Return table key for `#{{declaration.var}}`.
      def self.{{declaration.var}}
        {{key}}
      end
    {% end %}

    {% if options["primary_key"] %}
      PRIMARY_KEY = {{declaration.var.stringify}}
      PRIMARY_KEY_TYPE = {{declaration.type.resolve}}

      # Return primary key `Attribute` enum.
      def self.primary_key
        Attribute::{{declaration.var.camelcase}}
      end

      # Safely check for instance's primary key. Returns `nil` if not set.
      def primary_key?
        @{{declaration.var}}
      end

      # Strictly check for instance's primary key. Raises `ArgumentError` if not set.
      def primary_key
        raise ArgumentError.new("{{@type}}#primary_key must be called only if primary key is set. Consider calling #primary_key? instead") if @{{declaration.var}}.nil?
        return @{{declaration.var}}
      end

      # Equality check between two instances by their `primary_key`.
      # Raises `ArgumentError` if any of instances have primary key not set.
      def ==(other : self)
        self.primary_key == other.primary_key
      end
    {% end %}

    {%
      if reference
        CORE_REFERENCES.push({
          # E.g. `id`
          name: declaration.var,
          # Raw, as given (e.g. `Array(Post)?`)
          type: declaration.type.resolve,
          # Is this reference an enumerable? And if it is, which one (e.g. `Array` or `Set`)?
          enumerable: enumerable,
          # True reference type (e.g. `Post` for `Array(Post)`)
          true_type: reference,
          # Is the reference direct?
          direct: !!key && !options["foreign_key"],
          # Is the reference foreign?
          foreign: !key && !!options["foreign_key"],
          # The default value set on instance initialization
          default_instance_value: default_instance_value,
          # Can this reference be NULL on DB side?
          db_nilable: db_nilable,
          # Is this reference set to default on DB side?
          db_default: db_default,
          # Table key
          key: key,
          # Foreign table key
          foreign_key: options["foreign_key"],
        })
      else
        CORE_ATTRIBUTES.push({
          # E.g. `id`
          name: declaration.var,
          # Raw, as given (e.g. `Int32`)
          type: declaration.type.resolve,
          # True type (if within Union, would extract it)
          true_type: (declaration.type.resolve.union? ? declaration.type.resolve.union_types.find { |t| t != Nil } : declaration.type.resolve),
          # Is this type an enumerable?
          enumerable: enumerable,
          # If the type is an enumerable and its only type var <= DB::Any
          type_var_db_any: (enumerable && (declaration.type.resolve.type_vars.size) == 1 && (declaration.type.resolve.type_vars.first <= DB::Any)),
          # The default value set on instance initialization
          default_instance_value: default_instance_value,
          # Can this attribute be NULL on DB side?
          db_nilable: db_nilable,
          # Is this attribute set to default on DB side?
          db_default: db_default,
          # Is this attribute primary key?
          primary_key: options["primary_key"],
          # Table key
          key: key,
        })
      end
    %}
  end

  # Declare a primary key attribute. Supported syntaxes:
  #
  # - `pkey id` - alias of `type id : Int32 = DB::Default, primary_key: true`
  # - `pkey id : UUID` or `pkey id : UUID = UUID.random` - adds `primary_key: true` and `= DB::Default` if no default value
  macro pkey(declaration, **options)
    # `pkey id`
    {% if declaration.is_a?(Call) %}
      type({{declaration}}{{" : Int32 = DB::Default".id}}, primary_key: true, {{**options}})

    # `pkey id : Int32 (= value)`
    {% elsif declaration.is_a?(TypeDeclaration) %}
      type({{declaration.var}} : {{declaration.type}} = {{declaration.value ? declaration.value : DB::Default}}, primary_key: true, {{**options}})

    {% else %}
      {% raise "Unsupported pkey definition. Possible variants are 'pkey name' or 'pkey name : Type( = default_value)'" %}
    {% end %}
  end
end
