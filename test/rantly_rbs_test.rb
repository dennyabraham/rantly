# frozen_string_literal: true

require 'test_helper'
require 'rantly/minitest_extensions'
require 'rantly/rbs'

module RBSFixtures
  SEEN = [] # rubocop:disable Style/MutableConstant

  class Calc
    def add(left, right)
      SEEN << [left, right]
      left + right
    end

    def bad_return(number)
      number
    end

    def keywords(name:, times: 1)
      SEEN << [name, times]
      name * (times % 3)
    end

    def optional(number = 0)
      SEEN << number
      number
    end

    def union(value)
      SEEN << value
      value.to_s
    end

    def maybe(number)
      SEEN << number
      number || 0
    end

    def collect(numbers, lookup)
      SEEN << [numbers, lookup]
      numbers.sum + lookup.size
    end

    def with_block(&block)
      [1, 2].map(&block)
    end

    def strict(number)
      raise ArgumentError, 'negative' if number.negative?

      number
    end

    def explode(number)
      raise 'boom' if number
    end

    def anything(value)
      value
    end

    def interface(items)
      items.each.to_a.size
    end

    def extras(name:, **options)
      SEEN << [name, options]
      options.values.sum
    end

    def fails_over_ten(number)
      raise 'too big' if number > 10

      number
    end

    def long_array(numbers)
      raise 'too long' if numbers.size > 2

      numbers.size
    end

    def pick(value)
      raise "picked #{value}"
    end

    def self.make(number)
      number.to_s
    end
  end
end

module RBSFixtures
  class Account
    attr_reader :owner, :balance

    def initialize(owner:, balance: 0)
      @owner = owner
      @balance = balance
    end

    def deposit(amount)
      @balance += amount
    end

    def explode(amount)
      raise "exploded #{amount}"
    end

    def merge(other)
      @balance + other.balance
    end
  end

  class Node
    def initialize(link)
      @link = link
    end
  end
end

SIG = <<~RBS
  module RBSFixtures
    class Calc
      def add: (Integer, Integer) -> Integer
      def bad_return: (Integer) -> String
      def keywords: (name: String, ?times: Integer) -> String
      def optional: (?Integer) -> Integer
      def union: (Integer | String) -> String
      def maybe: (Integer?) -> Integer
      def collect: (Array[Integer], Hash[Symbol, String]) -> Integer
      def with_block: () { (Integer) -> String } -> Array[String]
      def strict: (Integer number) -> Integer
      def explode: (Integer) -> void
      def anything: (untyped) -> untyped
      def interface: (_Each[Integer]) -> Integer
      def extras: (name: String, **Integer options) -> Integer
      def fails_over_ten: (Integer number) -> Integer
      def long_array: (Array[Integer] numbers) -> Integer
      def pick: (5 | 7 value) -> void
      def self.make: (Integer) -> String
    end

    class Account
      def initialize: (owner: String, ?balance: Integer) -> void
      def deposit: (Integer) -> Integer
      def merge: (Account) -> Integer
      def explode: (Integer amount) -> void
    end

    class Node
      def initialize: (Node) -> void
    end
  end
RBS

describe 'Rantly RBS integration' do
  before do
    Rantly.gen.reset
    RBSFixtures::SEEN.clear
  end

  describe '#from_rbs' do
    def values_of(type, count = 50)
      Array.new(count) { Rantly.value { from_rbs(type) } }
    end

    it 'generates core scalar types' do
      assert(values_of('Integer').all?(Integer))
      assert(values_of('Float').all?(Float))
      assert(values_of('String').all?(String))
      assert(values_of('Symbol').all?(Symbol))
      assert(values_of('bool').all? { |value| [true, false].include?(value) })
      assert(values_of('nil').all?(NilClass))
    end

    it 'generates literals' do
      assert_equal [:ok], values_of(':ok').uniq
      assert_equal [42], values_of('42').uniq
    end

    it 'generates every branch of a union' do
      values = values_of('Integer | String | Symbol', 200)

      assert_equal [Integer, String, Symbol], values.map(&:class).uniq.sort_by(&:name)
    end

    it 'generates nil and non-nil for optional types' do
      values = values_of('Integer?', 200)

      assert_includes values, nil
      assert(values.compact.all?(Integer))
      refute_empty values.compact
    end

    it 'generates arrays, hashes, tuples and records' do
      assert(values_of('Array[Integer]').all? { |array| array.all?(Integer) })
      assert(values_of('Hash[Symbol, String]').all? do |hash|
        hash.all? { |key, value| key.is_a?(Symbol) && value.is_a?(String) }
      end)
      assert(values_of('[Integer, String]').all? { |(a, b)| a.is_a?(Integer) && b.is_a?(String) })
      assert(values_of('{ id: Integer, name: String }').all? do |hash|
        hash[:id].is_a?(Integer) && hash[:name].is_a?(String)
      end)
    end

    it 'generates nested types' do
      assert(values_of('Array[Integer | nil]').all? { |array| array.all? { |item| item.nil? || item.is_a?(Integer) } })
    end

    it 'generates a proc that returns the declared type' do
      procs = values_of('^(Integer) -> String', 5)

      assert(procs.all? { |callable| callable.call(1).is_a?(String) })
    end

    it 'can be used inside a property' do
      property_of { from_rbs('Array[Integer]') }.check(20) do |array|
        assert_kind_of Array, array
      end
    end

    it 'raises UnsupportedType for types with no generator' do
      assert_raises(Rantly::UnsupportedType) { Rantly.value { from_rbs('_Each[Integer]') } }
      assert_raises(Rantly::UnsupportedType) { Rantly.value { from_rbs('Rantly::NoSuchClass') } }
    end

    it 'builds instances of user classes from their initialize signature' do
      accounts = Array.new(20) { Rantly.value { from_rbs('::RBSFixtures::Account', sig: SIG) } }

      assert(accounts.all?(RBSFixtures::Account))
      assert(accounts.all? { |account| account.owner.is_a?(String) })
    end

    it 'gives up on classes that require themselves' do
      assert_raises(Rantly::UnsupportedType) { Rantly.value { from_rbs('::RBSFixtures::Node', sig: SIG) } }
    end

    it 'uses generators registered for a class' do
      Rantly.register_rbs_generator('RBSFixtures::Calc') { RBSFixtures::Calc.new }

      assert_kind_of(RBSFixtures::Calc, Rantly.value { from_rbs('::RBSFixtures::Calc') })
    ensure
      Rantly.rbs_generators.delete('RBSFixtures::Calc')
    end
  end

  describe '.check_method' do
    def check(method_name, **options)
      Rantly.check_method(RBSFixtures::Calc, method_name, sig: SIG, count: 25, **options)
    end

    it 'calls the method with arguments generated from its signature' do
      check(:add)

      assert_equal 25, RBSFixtures::SEEN.size
      assert(RBSFixtures::SEEN.all? { |pair| pair.all?(Integer) })
    end

    it 'fails when the return value does not match the signature' do
      error = assert_raises(Rantly::ReturnTypeError) { check(:bad_return) }

      assert_match(/bad_return/, error.message)
      assert_match(/String/, error.message)
    end

    it 'generates required and optional keywords' do
      check(:keywords)

      assert(RBSFixtures::SEEN.all? { |name, times| name.is_a?(String) && times.is_a?(Integer) })
    end

    it 'generates calls with and without optional arguments' do
      Rantly.check_method(RBSFixtures::Calc, :optional, sig: SIG, count: 100)

      assert_includes RBSFixtures::SEEN, 0
      assert(RBSFixtures::SEEN.all?(Integer))
    end

    it 'handles unions, optionals and collections' do
      check(:union)
      check(:maybe)
      check(:collect)

      assert_equal 75, RBSFixtures::SEEN.size
    end

    it 'passes a block that returns the declared block return type' do
      check(:with_block)
    end

    it 'checks singleton methods' do
      check(:make, singleton: true)
    end

    it 'treats untyped as any value' do
      check(:anything)
    end

    it 'fails when the method raises an unlisted exception' do
      error = assert_raises(ArgumentError) { check(:strict) }

      assert_match(/negative/, error.message)
    end

    it 'ignores exceptions listed in allow_raise' do
      check(:strict, allow_raise: [ArgumentError])
    end

    it 'uses overrides for named parameters' do
      check(:strict, overrides: { number: -> { range(0, 10) } })
      check(:keywords, overrides: { name: -> { 'fixed' }, times: 2 })

      assert_equal ['fixed'], RBSFixtures::SEEN.map(&:first).uniq
      # `times` is optional: it is either the override or the method's own default.
      assert_equal [1, 2], RBSFixtures::SEEN.map(&:last).uniq.sort
    end

    it 'generates keyword rest arguments of the declared type' do
      Rantly.check_method(RBSFixtures::Calc, :extras, sig: SIG, count: 100)

      options = RBSFixtures::SEEN.map(&:last)
      assert(options.any?(&:any?))
      assert(options.any?(&:empty?))
      assert(options.all? { |hash| hash.all? { |key, value| key.is_a?(Symbol) && value.is_a?(Integer) } })
      refute(options.any? { |hash| hash.key?(:name) })
    end

    it 'builds the receiver from the initialize signature' do
      Rantly.check_method(RBSFixtures::Account, :deposit, sig: SIG, count: 25)
    end

    it 'builds arguments that are user classes' do
      Rantly.check_method(RBSFixtures::Account, :merge, sig: SIG, count: 25)
    end

    it 'uses a given receiver' do
      receiver = RBSFixtures::Calc.new
      check(:add, receiver: -> { receiver })

      assert_equal 25, RBSFixtures::SEEN.size
    end

    it 'reports unsupported parameter types' do
      assert_raises(Rantly::UnsupportedType) { check(:interface) }
    end

    it 'reports methods without a signature' do
      error = assert_raises(ArgumentError) { check(:nothing_here) }

      assert_match(/nothing_here/, error.message)
    end
  end

  describe 'shrinking' do
    def failing_message(method_name, klass: RBSFixtures::Calc, **options)
      error = assert_raises(RuntimeError) do
        Rantly.check_method(klass, method_name, sig: SIG, count: 50, **options)
      end
      error.message
    end

    it 'shrinks integer arguments while the call still fails' do
      shrunk = failing_message(:fails_over_ten)[/Shrunk to: .*fails_over_ten\((-?\d+)\)/, 1]

      assert shrunk, 'expected the message to name a shrunk call'
      assert((11..21).cover?(shrunk.to_i), "expected 11..21, got #{shrunk}")
    end

    it 'shrinks array arguments by shrinking then dropping elements' do
      assert_match(/Shrunk to: .*long_array\(\[0, 0, 0\]\)/, failing_message(:long_array))
    end

    it 'never shrinks a value outside its declared type' do
      assert_match(/Shrunk to: .*pick\((5|7)\)/, failing_message(:pick))
    end

    it 'does not shrink overridden parameters' do
      message = failing_message(:fails_over_ten, overrides: { number: -> { 100 } })

      assert_match(/Shrunk to: .*fails_over_ten\(100\)/, message)
    end

    it 'shows the receiver of the failing call' do
      message = failing_message(:explode, klass: RBSFixtures::Account)

      assert_match(/Shrunk to: .*Account#explode\(.*\) on RBSFixtures::Account\.new\(owner: /, message)
    end
  end
end
