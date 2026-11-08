# frozen_string_literal: true

begin
  require 'rbs'
  require 'rbs/test'
rescue LoadError => e
  raise LoadError, "rantly/rbs requires the rbs gem: #{e.message}"
end

require 'rantly'
require 'rantly/property'

# Generates values and method calls from RBS type signatures.
#
#   require 'rantly/rbs'
#
#   Rantly.value { from_rbs('Array[Integer | nil]') }
#   Rantly.check_method(Foo, :bar, allow_raise: [ArgumentError])
class Rantly
  class UnsupportedType < RuntimeError; end

  class ReturnTypeError < RuntimeError; end

  # Support for loading signatures. Kept apart from Rantly so the ::RBS constant is never shadowed.
  module RBSSupport
    class << self
      # @param sig [String, nil] extra signature source, e.g. for tests.
      # @param env [RBS::Environment, nil] a resolved environment. Defaults to core plus ./sig if present.
      def builder(sig: nil, env: nil)
        return ::RBS::DefinitionBuilder.new(env: env) if env

        # Loading core signatures is slow, so builders for the default environment are reused.
        (@builders ||= {})[sig] ||= ::RBS::DefinitionBuilder.new(env: build_environment(sig: sig))
      end

      def type_name(klass)
        *path, name = klass.name.split('::').map(&:to_sym)
        ::RBS::TypeName.new(name: name, namespace: ::RBS::Namespace.new(path: path, absolute: true))
      end

      # Forget loaded signatures, e.g. after editing files in ./sig.
      def reset!
        @builders = {}
      end

      private

      def build_environment(sig:)
        loader = ::RBS::EnvironmentLoader.new
        loader.add(path: Pathname('sig')) if Dir.exist?('sig')
        env = ::RBS::Environment.from_loader(loader)

        if sig
          buffer, directives, decls = ::RBS::Parser.parse_signature(::RBS::Buffer.new(name: 'inline.rbs', content: sig))
          env.add_signature(buffer: buffer, directives: directives, decls: decls)
        end

        env.resolve_type_names
      end
    end
  end

  # Generators for classes RBS knows by name. Values are blocks evaluated inside a Rantly instance.
  @rbs_generators = {}

  class << self
    attr_reader :rbs_generators

    # Registers how to generate instances of a class, e.g. one that has no generator built in.
    #
    #   Rantly.register_rbs_generator('User') { User.new(name: string(:alpha)) }
    def register_rbs_generator(class_name, &block)
      @rbs_generators[class_name.to_s.delete_prefix('::')] = block
    end

    # Calls +method_name+ on +klass+ with arguments generated from its RBS signature and checks every return value
    # against the signature. Exceptions raised by the method fail the check unless listed in +allow_raise+.
    #
    # @param sig [String] extra RBS source, loaded on top of core and ./sig.
    # @param env [RBS::Environment] a resolved environment to use instead of loading one.
    # @param singleton [Boolean] check a class method instead of an instance method.
    # @param receiver [#call] returns the object to call the method on. Defaults to +klass.new+.
    # @param overrides [Hash] parameter name => generator (Proc or Symbol) or literal value.
    # @param allow_raise [Array<Class>] exceptions that count as a valid outcome.
    def check_method(klass, method_name, count: Rantly::Property::RANTLY_COUNT, sig: nil, env: nil, singleton: false, # rubocop:disable Metrics/ParameterLists
                     receiver: nil, overrides: {}, allow_raise: [])
      builder = RBSSupport.builder(sig: sig, env: env)
      method = find_rbs_method(builder, klass, method_name, singleton: singleton)
      checker = ::RBS::Test::TypeCheck.new(self_class: klass, builder: builder, sample_size: 100, unchecked_classes: [])

      generator = proc do
        method_type = choose(*method.method_types)
        instance = singleton || receiver ? nil : rbs_new(RBSSupport.type_name(klass), builder, 0)
        [method_type, *rbs_arguments(method_type, builder, overrides), instance]
      end

      Rantly::Property.new(generator).check(count) do |(method_type, args, kwargs, block, instance)|
        target = singleton ? klass : (instance || receiver.call)

        begin
          result = target.public_send(method_name, *args, **kwargs, &block)
        rescue *allow_raise
          next
        end

        verify_rbs_return(checker, result, method_type, "#{klass}#{singleton ? '.' : '#'}#{method_name}")
      end
    end

    private

    def verify_rbs_return(checker, result, method_type, description)
      return_type = method_type.type.return_type
      return if checker.value(result, return_type)

      raise ReturnTypeError,
            "#{description} returned #{result.inspect}, expected #{return_type} (signature: #{method_type})"
    end

    def find_rbs_method(builder, klass, method_name, singleton:)
      type_name = RBSSupport.type_name(klass)
      definition = singleton ? builder.build_singleton(type_name) : builder.build_instance(type_name)

      definition.methods[method_name] or
        raise ArgumentError, "no RBS signature for #{klass}#{singleton ? '.' : '#'}#{method_name}"
    end
  end

  # Value generation from RBS types. Included into Rantly, so it can be called inside property blocks.
  module RBSGenerators # rubocop:disable Metrics/ModuleLength
    MAX_DEPTH = 3
    MAX_NEW_DEPTH = 6
    CORE_SCALARS = %w[Integer Float Numeric String Symbol NilClass TrueClass FalseClass Object Time].freeze

    # @param type [String, RBS::Types::t] an RBS type such as +"Array[Integer | nil]"+
    def from_rbs(type, env: nil, sig: nil)
      type = ::RBS::Parser.parse_type(type) if type.is_a?(String)
      rbs_value(type, RBSSupport.builder(sig: sig, env: env), 0)
    end

    def rbs_value(type, builder, depth = 0) # rubocop:disable Metrics/CyclomaticComplexity
      case type
      when ::RBS::Types::Bases::Bool then boolean
      when ::RBS::Types::Bases::Nil, ::RBS::Types::Bases::Void then nil
      when ::RBS::Types::Bases::Any, ::RBS::Types::Bases::Top then rbs_untyped
      when ::RBS::Types::Literal then type.literal
      when ::RBS::Types::Optional then range(0, 3).zero? ? nil : rbs_value(type.type, builder, depth)
      when ::RBS::Types::Union then rbs_value(choose(*type.types), builder, depth)
      when ::RBS::Types::Tuple then type.types.map { |item| rbs_value(item, builder, depth + 1) }
      when ::RBS::Types::Record then rbs_record(type, builder, depth)
      when ::RBS::Types::Alias then rbs_value(builder.expand_alias2(rbs_absolute(type.name), type.args), builder, depth)
      when ::RBS::Types::ClassInstance then rbs_class_instance(type, builder, depth)
      when ::RBS::Types::Proc then rbs_proc(type, builder, depth)
      else raise UnsupportedType, "no generator for RBS type `#{type}`"
      end
    end

    # Arguments for one call: [positional args, keyword args, block or nil].
    def rbs_arguments(method_type, builder, overrides, depth = 0)
      function = method_type.type
      raise UnsupportedType, "untyped parameters in `#{method_type}`" unless function.is_a?(::RBS::Types::Function)

      args = rbs_positionals(function, builder, overrides, depth)
      kwargs = rbs_keywords(function, builder, overrides, depth)
      [args, kwargs, rbs_block(method_type.block, builder, depth)]
    end

    private

    def rbs_positionals(function, builder, overrides, depth)
      optionals = function.optional_positionals.first(range(0, function.optional_positionals.size))
      rest = function.rest_positionals ? Array.new(range(0, 2), function.rest_positionals) : []

      [*function.required_positionals, *optionals, *rest, *function.trailing_positionals].map do |param|
        rbs_param_value(param, builder, overrides, depth)
      end
    end

    def rbs_keywords(function, builder, overrides, depth)
      required = function.required_keywords
      optional = function.optional_keywords.select { boolean }

      required.merge(optional).to_h do |name, param|
        [name, rbs_param_value(param, builder, overrides, depth, name: name)]
      end
    end

    def rbs_param_value(param, builder, overrides, depth, name: param.name)
      return rbs_value(param.type, builder, depth + 1) unless overrides.key?(name)

      override = overrides[name]
      case override
      when Proc then instance_exec(&override)
      when Symbol then call(override)
      else override
      end
    end

    def rbs_block(block, builder, depth)
      return unless block && (block.required || boolean)

      generator = self
      return_type = block.type.return_type
      proc { |*| generator.rbs_value(return_type, builder, depth + 1) }
    end

    def rbs_record(type, builder, depth)
      required = type.fields.transform_values { |field| rbs_value(field, builder, depth + 1) }
      optional_fields = type.respond_to?(:optional_fields) ? type.optional_fields : {}
      optional = optional_fields.select { boolean }.transform_values { |field| rbs_value(field, builder, depth + 1) }
      required.merge(optional)
    end

    def rbs_proc(type, builder, depth)
      generator = self
      return_type = type.type.return_type
      ->(*_args, **_kwargs, &_block) { generator.rbs_value(return_type, builder, depth + 1) }
    end

    def rbs_untyped
      case range(0, 4)
      when 0 then integer
      when 1 then rbs_string
      when 2 then nil
      when 3 then boolean
      else rbs_symbol
      end
    end

    def rbs_absolute(name)
      name.absolute? ? name : name.absolute!
    end

    def rbs_class_instance(type, builder, depth)
      name = type.name.to_s.delete_prefix('::')
      args = type.args

      if (custom = Rantly.rbs_generators[name])
        return instance_eval(&custom)
      end

      case name
      when 'Array' then rbs_array(args.first, builder, depth)
      when 'Set' then rbs_array(args.first, builder, depth).to_set
      when 'Hash' then rbs_hash(args, builder, depth)
      when 'Range' then rbs_range(args.first, builder, depth)
      else CORE_SCALARS.include?(name) ? rbs_core_scalar(name) : rbs_new(type.name, builder, depth)
      end
    end

    # Builds an instance by generating arguments for the `new` signature RBS derives from `initialize`.
    def rbs_new(type_name, builder, depth)
      raise UnsupportedType, "`#{type_name}` needs itself to be built" if depth > MAX_NEW_DEPTH

      klass, method_types = rbs_constructor(rbs_absolute(type_name), builder)
      args, kwargs, block = rbs_arguments(choose(*method_types), builder, {}, depth + 1)
      klass.new(*args, **kwargs, &block)
    end

    def rbs_constructor(type_name, builder)
      klass = Object.const_get(type_name.to_s.delete_prefix('::'))
      [klass, builder.build_singleton(type_name).methods.fetch(:new).method_types]
    rescue ::RBS::BaseError, NameError, KeyError => e
      raise UnsupportedType, "no generator for class `#{type_name}`: #{e.message.lines.first&.strip}"
    end

    def rbs_core_scalar(name) # rubocop:disable Metrics/CyclomaticComplexity
      case name
      when 'Integer' then integer
      when 'Float' then float(:normal, scale: 100)
      when 'Numeric' then boolean ? integer : float(:normal, scale: 100)
      when 'String' then rbs_string
      when 'Symbol' then rbs_symbol
      when 'NilClass' then nil
      when 'TrueClass' then true
      when 'FalseClass' then false
      when 'Object' then rbs_untyped
      when 'Time' then Time.at(range(0, 2**31))
      else raise UnsupportedType, "no generator for class `#{name}`; see Rantly.register_rbs_generator"
      end
    end

    def rbs_string
      sized(range(0, size)) { string(:print) }
    end

    def rbs_symbol
      sized(range(1, [size, 1].max)) { string(:alpha) }.to_sym
    end

    def rbs_length(depth)
      depth > MAX_DEPTH ? 0 : range(0, size)
    end

    def rbs_array(item_type, builder, depth)
      return Array.new(rbs_length(depth)) { rbs_untyped } unless item_type

      Array.new(rbs_length(depth)) { rbs_value(item_type, builder, depth + 1) }
    end

    def rbs_hash(args, builder, depth)
      key_type, value_type = args
      rbs_length(depth).times.with_object({}) do |_, hash|
        key = key_type ? rbs_value(key_type, builder, depth + 1) : rbs_symbol
        hash[key] = value_type ? rbs_value(value_type, builder, depth + 1) : rbs_untyped
      end
    end

    def rbs_range(bound_type, builder, depth)
      low, high = Array.new(2) { rbs_value(bound_type || ::RBS::Types::Bases::Any.new(location: nil), builder, depth + 1) }
      low, high = [low, high].sort
      low..high
    rescue ArgumentError, NoMethodError
      raise UnsupportedType, "cannot order values of `#{bound_type}` to build a Range"
    end
  end

  include RBSGenerators
end
