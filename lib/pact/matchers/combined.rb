# frozen_string_literal: true

module Pact
  module Matchers
    # Applies several matchers to the same path, combined with AND or OR logic.
    #
    # Serialises to pact_ffi integration JSON, with every matcher (without its
    # example value) in the `pact:matcher:type` array and the sample as the
    # single `value`:
    #
    #   {
    #     "pact:matcher:type": [{"pact:matcher:type": "type"}, {"pact:matcher:type": "null"}],
    #     "pact:matcher:combine": "OR",
    #     "value": "Fred"
    #   }
    #
    # Requires a pact_ffi version that supports `pact:matcher:combine`
    # (pact-foundation/pact-reference#601).
    class Combined < Base
      VALID_COMBINATIONS = %i[and or].freeze

      attr_reader :matchers, :combine

      def initialize(matchers, combine:, template:)
        raise ArgumentError, 'At least two matchers are required' if matchers.size < 2

        unless matchers.all? { |m| m.is_a?(Pact::Matchers::Base) && !m.is_a?(Combined) }
          raise ArgumentError, 'All values must be Pact matchers'
        end

        raise ArgumentError, 'combine must be :and or :or' unless VALID_COMBINATIONS.include?(combine)

        @matchers = matchers
        @combine = combine
        super(spec_version: Pact::Matchers::PACT_SPEC_V3, kind: matchers.map(&:kind), template: template)
      end

      def as_basic
        {
          'pact:matcher:type' => matchers.map { |m| m.as_basic.except('value') },
          'pact:matcher:combine' => combine.to_s.upcase,
          'value' => serialize!(template.deep_dup, :basic)
        }
      end

      def as_plugin
        raise MatcherInitializationError,
              "#{self.class}: combined (match_#{combine}) matchers are not supported in plugin contents"
      end
    end
  end
end
