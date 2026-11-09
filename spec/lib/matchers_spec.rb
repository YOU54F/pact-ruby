# frozen_string_literal: true

RSpec.describe Pact::Matchers do
  subject(:test_class) { Class.new { extend Pact::Matchers } }

  describe '#match_or' do
    subject(:matcher) do
      test_class.match_or(
        boolean_matcher,
        null_matcher,
        sample: true
      )
    end

    let(:boolean_matcher) { test_class.match_any_boolean(true) }
    let(:null_matcher) { test_class.match_null }

    it 'creates an OR combination of the provided matchers' do
      expect(matcher).to have_attributes(
        combine: :or,
        template: true,
        matchers: [boolean_matcher, null_matcher]
      )
    end

    it 'requires at least two matchers' do
      expect do
        test_class.match_or(test_class.match_any_boolean(true), sample: true)
      end.to raise_error(
        ArgumentError,
        'At least two matchers are required'
      )
    end

    it 'only accepts Pact matchers' do
      expect do
        test_class.match_or(
          test_class.match_any_boolean(true),
          :invalid,
          sample: true
        )
      end.to raise_error(
        ArgumentError,
        'All values must be Pact matchers'
      )
    end
  end

  describe '#match_and' do
    subject(:matcher) do
      test_class.match_and(
        boolean_matcher,
        null_matcher,
        sample: true
      )
    end

    let(:boolean_matcher) { test_class.match_any_boolean(true) }
    let(:null_matcher) { test_class.match_null }

    it 'creates an AND combination of the provided matchers' do
      expect(matcher).to have_attributes(
        combine: :and,
        template: true,
        matchers: [boolean_matcher, null_matcher]
      )
    end

    it 'requires at least two matchers' do
      expect do
        test_class.match_and(test_class.match_any_boolean(true), sample: true)
      end.to raise_error(
        ArgumentError,
        'At least two matchers are required'
      )
    end

    it 'only accepts Pact matchers' do
      expect do
        test_class.match_and(
          test_class.match_any_boolean(true),
          :invalid,
          sample: true
        )
      end.to raise_error(
        ArgumentError,
        'All values must be Pact matchers'
      )
    end
  end

  context 'with combined matchers serialized to integration JSON' do
    it 'serializes match_or with each matcher (without its value) and the sample as the value' do
      matcher = test_class.match_or(test_class.match_type_of('Fred'), test_class.match_null, sample: 'Fred')

      expect(JSON.parse(matcher.as_basic.to_json)).to eq(
        'pact:matcher:type' => [{ 'pact:matcher:type' => 'type' }, { 'pact:matcher:type' => 'null' }],
        'pact:matcher:combine' => 'OR',
        'value' => 'Fred'
      )
    end

    it 'serializes match_and with AND' do
      matcher = test_class.match_and(test_class.match_regex(/\d+/, '12'), test_class.match_include('1'), sample: '12')

      expect(JSON.parse(matcher.as_basic.to_json)).to eq(
        'pact:matcher:type' => [
          { 'pact:matcher:type' => 'regex', 'regex' => '(?-mix:\d+)' },
          { 'pact:matcher:type' => 'include' }
        ],
        'pact:matcher:combine' => 'AND',
        'value' => '12'
      )
    end

    it 'keeps matcher attributes on each alternative' do
      expect(JSON.parse(test_class.match_datetime_or_nil('yyyy-MM-dd', '2020-05-21').as_basic.to_json)).to eq(
        'pact:matcher:type' => [
          { 'pact:matcher:type' => 'datetime', 'format' => 'yyyy-MM-dd' },
          { 'pact:matcher:type' => 'null' }
        ],
        'pact:matcher:combine' => 'OR',
        'value' => '2020-05-21'
      )
    end

    it 'serializes nested matchers inside an object sample (null-or-object)' do
      matcher = test_class.match_or(
        test_class.match_type_of({}), test_class.match_null,
        sample: { street: 'Main St', number: test_class.match_any_integer(42) }
      )

      expect(JSON.parse(matcher.as_basic.to_json)).to eq(
        'pact:matcher:type' => [{ 'pact:matcher:type' => 'type' }, { 'pact:matcher:type' => 'null' }],
        'pact:matcher:combine' => 'OR',
        'value' => { 'street' => 'Main St', 'number' => { 'pact:matcher:type' => 'integer', 'value' => 42 } }
      )
    end

    it 'emits a null value when the sample is nil' do
      matcher = test_class.match_or(test_class.match_null, test_class.match_any_integer(1), sample: nil)

      expect(matcher.as_basic).to include('value' => nil)
    end

    {
      match_any_string_or_nil: [['any'], { 'pact:matcher:type' => 'regex', 'regex' => '(?-mix:.*)' }, 'any'],
      match_any_integer_or_nil: [[], { 'pact:matcher:type' => 'integer' }, 10],
      match_any_decimal_or_nil: [[], { 'pact:matcher:type' => 'decimal' }, 10.0],
      match_any_number_or_nil: [[], { 'pact:matcher:type' => 'number' }, 10.0],
      match_any_boolean_or_nil: [[], { 'pact:matcher:type' => 'boolean' }, true],
      match_date_or_nil: [%w[yyyy-MM-dd 2020-05-21], { 'pact:matcher:type' => 'date', 'format' => 'yyyy-MM-dd' },
                          '2020-05-21'],
      match_time_or_nil: [%w[HH:mm 16:44], { 'pact:matcher:type' => 'time', 'format' => 'HH:mm' }, '16:44']
    }.each do |helper, (args, first_rule, sample)|
      it "#{helper} serializes to <matcher> OR null" do
        expect(JSON.parse(test_class.public_send(helper, *args).as_basic.to_json)).to eq(
          'pact:matcher:type' => [first_rule, { 'pact:matcher:type' => 'null' }],
          'pact:matcher:combine' => 'OR',
          'value' => sample
        )
      end
    end

    it 'rejects a combined matcher as an alternative' do
      inner = test_class.match_any_string_or_nil('x')

      expect { test_class.match_or(inner, test_class.match_any_integer(1), sample: 'x') }
        .to raise_error(ArgumentError, 'All values must be Pact matchers')
    end

    it 'is not supported in plugin contents' do
      expect { test_class.match_any_string_or_nil('x').as_plugin }
        .to raise_error(Pact::Matchers::Base::MatcherInitializationError, /not supported in plugin contents/)
    end
  end

  context 'with basic format serialization' do
    it 'properly builds matcher for null' do
      expect(test_class.match_null.as_basic).to eq({
                                                     'pact:matcher:type' => 'null'
                                                   })
    end

    it 'properly builds matcher for UUID' do
      expect(test_class.match_uuid.as_basic).to eq({
                                                     'pact:matcher:type' => 'regex',
                                                     'value' => 'e1d01e04-3a2b-4eed-a4fb-54f5cd257338',
                                                     :regex => '(?i-mx:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})' # rubocop:disable Layout/LineLength
                                                   })
    end

    it 'properly builds matcher for regex' do
      expect(test_class.match_regex(/(A-Z){1,3}/, 'ABC').as_basic).to eq({
                                                                           'pact:matcher:type' => 'regex',
                                                                           'value' => 'ABC',
                                                                           :regex => '(?-mix:(A-Z){1,3})'
                                                                         })
    end

    it 'properly builds matcher for datetime' do
      expect(test_class.match_datetime('yyyy-MM-dd HH:mm:ssZZZZZ', '2020-05-21 16:44:32+10:00').as_basic).to eq({
                                                                                                                  'pact:matcher:type' => 'datetime', # rubocop:disable Layout/LineLength
                                                                                                                  'value' => '2020-05-21 16:44:32+10:00', # rubocop:disable Layout/LineLength
                                                                                                                  :format => 'yyyy-MM-dd HH:mm:ssZZZZZ' # rubocop:disable Layout/LineLength
                                                                                                                })
    end

    it 'properly builds matcher for iso8601' do
      expect(test_class.match_iso8601('2020-05-21T16:44:32').as_basic).to eq({
                                                                               'pact:matcher:type' => 'regex',
                                                                               'value' => '2020-05-21T16:44:32',
                                                                               :regex => '(?i-mx:\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)*(.\\d{2}:\\d{2})*)' # rubocop:disable Layout/LineLength
                                                                             })
    end

    it 'properly builds matcher for date' do
      expect(test_class.match_date('yyyy-MM-dd', '2020-05-21').as_basic).to eq({
                                                                                 'pact:matcher:type' => 'date',
                                                                                 'value' => '2020-05-21',
                                                                                 :format => 'yyyy-MM-dd'
                                                                               })
    end

    it 'properly builds matcher for time' do
      expect(test_class.match_time('HH:mm:ss', '16:44:32').as_basic).to eq({
                                                                             'pact:matcher:type' => 'time',
                                                                             'value' => '16:44:32',
                                                                             :format => 'HH:mm:ss'
                                                                           })
    end

    it 'properly builds matcher for include' do
      expect(test_class.match_include('some string').as_basic).to eq({
                                                                       'pact:matcher:type' => 'include',
                                                                       'value' => 'some string'
                                                                     })
    end

    it 'properly builds matcher for any string' do
      expect(test_class.match_any_string.as_basic).to eq({
                                                           'pact:matcher:type' => 'regex',
                                                           'value' => 'any',
                                                           :regex => '(?-mix:.*)'
                                                         })
      expect(test_class.match_any_string('').as_basic).to eq({
                                                               'pact:matcher:type' => 'regex',
                                                               'value' => '',
                                                               :regex => '(?-mix:.*)'
                                                             })
    end

    it 'properly builds matcher for boolean values' do
      expect(test_class.match_any_boolean.as_basic).to eq({
                                                            'pact:matcher:type' => 'boolean',
                                                            'value' => true
                                                          })
    end

    it 'properly builds matcher for integer values' do
      expect(test_class.match_any_integer.as_basic).to eq({
                                                            'pact:matcher:type' => 'integer',
                                                            'value' => 10
                                                          })
    end

    it 'properly builds matcher for float values' do
      expect(test_class.match_any_decimal.as_basic).to eq({
                                                            'pact:matcher:type' => 'decimal',
                                                            'value' => 10.0
                                                          })
    end

    it 'properly builds matcher for exact values' do
      expect(test_class.match_exactly('some arg').as_basic).to eq({
                                                                    'pact:matcher:type' => 'equality',
                                                                    'value' => 'some arg'
                                                                  })
      expect(test_class.match_exactly(1).as_basic).to eq({
                                                           'pact:matcher:type' => 'equality',
                                                           'value' => 1
                                                         })
      expect(test_class.match_exactly(true).as_basic).to eq({
                                                              'pact:matcher:type' => 'equality',
                                                              'value' => true
                                                            })
    end

    it 'properly builds typed matcher' do
      expect(test_class.match_type_of(1).as_basic).to eq({
                                                           'pact:matcher:type' => 'type',
                                                           'value' => 1
                                                         })
      expect { test_class.match_type_of(Object.new).as_basic }.to raise_error(/is not a primitive/)
    end

    it 'properly builds each matcher' do
      expect(test_class.match_each(1).as_basic).to eq({
                                                        'pact:matcher:type' => 'type',
                                                        'value' => [1],
                                                        :min => 1
                                                      })
      expect(test_class.match_each(true).as_basic).to eq({
                                                           'pact:matcher:type' => 'type',
                                                           'value' => [true],
                                                           :min => 1
                                                         })
      expect(test_class.match_each('some').as_basic).to eq({
                                                             'pact:matcher:type' => 'type',
                                                             'value' => ['some'],
                                                             :min => 1
                                                           })
      expect(test_class.match_each(
        {
          str: test_class.match_any_string('str'),
          bool: test_class.match_any_boolean(true),
          num: test_class.match_any_number(1),
          nested: test_class.match_each(
            {
              a: 1,
              b: '2'
            }
          )
        }
      ).as_basic).to eq({
                          'pact:matcher:type' => 'type',
                          'value' => [
                            {
                              str: {
                                'pact:matcher:type' => 'regex',
                                :regex => '(?-mix:.*)',
                                'value' => 'str'
                              },
                              bool: {
                                'pact:matcher:type' => 'boolean',
                                'value' => true
                              },
                              num: {
                                'pact:matcher:type' => 'number',
                                'value' => 1
                              },
                              nested: {
                                'pact:matcher:type' => 'type',
                                'value' => [
                                  { a: 1, b: '2' }
                                ],
                                :min => 1
                              }
                            }
                          ],
                          :min => 1
                        })
    end

    it 'properly builds each-key matcher' do
      expect(test_class.match_each_key({ 'some-key' => 'value' },
                                       test_class.match_regex(/\w+-\w+/, 'some-key')).as_basic).to eq(
                                         {
                                           'pact:matcher:type' => 'each-key',
                                           :rules => [
                                             {
                                               'pact:matcher:type' => 'regex',
                                               :regex => '(?-mix:\\w+-\\w+)',
                                               'value' => 'some-key'
                                             }
                                           ],
                                           'value' => { 'some-key' => 'value' }
                                         }
                                       )
      expect(test_class.match_each_key({ 'some-key' => { 'value1' => 1, 'value2' => 2 } },
                                       test_class.match_regex(/\w+-\w+/, 'some-key')).as_basic).to eq(
                                         {
                                           'pact:matcher:type' => 'each-key',
                                           :rules => [
                                             {
                                               'pact:matcher:type' => 'regex',
                                               :regex => '(?-mix:\\w+-\\w+)',
                                               'value' => 'some-key'
                                             }
                                           ],
                                           'value' => { 'some-key' => { 'value1' => 1, 'value2' => 2 } }
                                         }
                                       )
    end

    it 'properly builds each-value matcher' do
      expect(test_class.match_each_value({ 'some-key' => 'value' },
                                         test_class.match_regex(/\w+/, 'value')).as_basic).to eq(
                                           {
                                             'pact:matcher:type' => 'each-value',
                                             :rules => [
                                               {
                                                 'pact:matcher:type' => 'regex',
                                                 :regex => '(?-mix:\\w+)',
                                                 'value' => 'value'
                                               }
                                             ],
                                             'value' => { 'some-key' => 'value' }
                                           }
                                         )
      expect(test_class.match_each_value(
        { 'some-key' => { 'value1' => test_class.match_any_string('1'), 'value2' => test_class.match_any_number(2) } },
        test_class.match_regex(/\w+-\w+/, 'some-key')
      ).as_basic).to eq(
        {
          'pact:matcher:type' => 'each-value',
          :rules => [
            {
              'pact:matcher:type' => 'regex',
              :regex => '(?-mix:\\w+-\\w+)',
              'value' => 'some-key'
            }
          ],
          'value' => {
            'some-key' => {
              'value1' => {
                'pact:matcher:type' => 'regex',
                :regex => '(?-mix:.*)',
                'value' => '1'
              },
              'value2' => {
                'pact:matcher:type' => 'number',
                'value' => 2
              }
            }
          }
        }
      )
    end

    it 'properly builds each-key-value matcher' do
      expect(test_class.match_each_kv(
        {
          'some-key' => {
            'value1' => test_class.match_any_string('1')
          }
        }, test_class.match_regex(/\w+/, 'value')
      ).as_basic).to eq({
                          'pact:matcher:type' => [
                            {
                              'pact:matcher:type' => 'each-key',
                              :rules => [
                                {
                                  'pact:matcher:type' => 'regex',
                                  :regex => '(?-mix:\\w+)',
                                  'value' => 'value'
                                }
                              ],
                              'value' => {}
                            },
                            {
                              'pact:matcher:type' => 'each-value',
                              :rules => [
                                {
                                  'pact:matcher:type' => 'type',
                                  'value' => ''
                                }
                              ],
                              'value' => {}
                            }
                          ],
                          'value' => {
                            'some-key' => {
                              'value1' => {
                                'pact:matcher:type' => 'regex',
                                :regex => '(?-mix:.*)',
                                'value' => '1'
                              }
                            }
                          }
                        })
    end

    it 'properly builds semver matcher' do
      expect(test_class.match_semver.as_basic).to eq({
                                                       'pact:matcher:type' => 'semver'
                                                     })
    end
    it 'properly builds content_type matcher' do
      expect(test_class.match_content_type('application/xml').as_basic).to eq({
                                                                                'pact:matcher:type' => 'contentType',
                                                                                'value' => 'application/xml'
                                                                              })
    end
    it 'properly builds not_empty matcher' do
      expect(test_class.match_not_empty.as_basic).to eq({
                                                          'pact:matcher:type' => 'notEmpty'
                                                        })
    end

    it 'properly builds values matcher' do
      expect(Pact::Matchers::V3::Values.new.as_basic).to eq({
                                                              'pact:matcher:type' => 'values'
                                                            })
    end

    it 'properly builds null matcher' do
      expect(Pact::Matchers::V3::Null.new.as_basic).to eq({
                                                            'pact:matcher:type' => 'null'
                                                          })
    end

    it 'properly builds status_code matcher' do
      expect(test_class.match_status_code(200).as_basic).to eq({
                                                                 'pact:matcher:type' => 'statusCode',
                                                                 'status' => 200
                                                               })
      expect(test_class.match_status_code('nonError').as_basic).to eq({
                                                                        'pact:matcher:type' => 'statusCode',
                                                                        'status' => 'nonError'
                                                                      })
    end
  end

  context 'with plugin format serialization' do
    it 'properly builds matcher for UUID' do
      expect(test_class.match_uuid.as_plugin).to eq("matching(regex, '(?i-mx:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', 'e1d01e04-3a2b-4eed-a4fb-54f5cd257338')") # rubocop:disable Layout/LineLength
    end

    it 'properly builds matcher for regex' do
      expect(test_class.match_regex(/(A-Z){1,3}/,
                                    'ABC').as_plugin).to eq("matching(regex, '(?-mix:(A-Z){1,3})', 'ABC')")
    end

    it 'properly builds matcher for datetime' do
      expect(test_class.match_datetime('yyyy-MM-dd HH:mm:ssZZZZZ',
                                       '2020-05-21 16:44:32+10:00').as_plugin).to eq("matching(datetime, 'yyyy-MM-dd HH:mm:ssZZZZZ', '2020-05-21 16:44:32+10:00')") # rubocop:disable Layout/LineLength
    end

    it 'properly builds matcher for iso8601' do
      expect(test_class.match_iso8601('2020-05-21T16:44:32').as_plugin).to eq("matching(regex, '(?i-mx:\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)*(.\\d{2}:\\d{2})*)', '2020-05-21T16:44:32')") # rubocop:disable Layout/LineLength
    end

    it 'properly builds matcher for date' do
      expect(test_class.match_date('yyyy-MM-dd',
                                   '2020-05-21').as_plugin).to eq("matching(date, 'yyyy-MM-dd', '2020-05-21')")
    end

    it 'properly builds matcher for time' do
      expect(test_class.match_time('HH:mm:ss', '16:44:32').as_plugin).to eq("matching(time, 'HH:mm:ss', '16:44:32')")
    end

    it 'properly builds matcher for include' do
      expect(test_class.match_include('some string').as_plugin).to eq("matching(include, 'some string')")
    end

    it 'properly builds matcher for any string' do
      expect(test_class.match_any_string.as_plugin).to eq("matching(regex, '(?-mix:.*)', 'any')")
      expect(test_class.match_any_string('').as_plugin).to eq("matching(regex, '(?-mix:.*)', '')")
    end

    it 'properly builds matcher for boolean values' do
      expect(test_class.match_any_boolean.as_plugin).to eq('matching(boolean, true)')
    end

    it 'properly builds matcher for integer values' do
      expect(test_class.match_any_integer.as_plugin).to eq('matching(integer, 10)')
    end

    it 'properly builds matcher for float values' do
      expect(test_class.match_any_decimal.as_plugin).to eq('matching(decimal, 10.0)')
    end

    it 'properly builds matcher for exact values' do
      expect(test_class.match_exactly('some arg').as_plugin).to eq("matching(equalTo, 'some arg')")
      expect(test_class.match_exactly(1).as_plugin).to eq('matching(equalTo, 1)')
      expect(test_class.match_exactly(true).as_plugin).to eq('matching(equalTo, true)')
    end

    it 'properly builds typed matcher' do
      expect(test_class.match_type_of(1).as_plugin).to eq('matching(type, 1)')
      expect { test_class.match_type_of(Object.new).as_plugin }.to raise_error(/is not a primitive/)
    end

    it 'properly builds each matcher' do
      expect(test_class.match_each(1).as_plugin).to eq('eachValue(matching(type, 1))')
      expect(test_class.match_each(true).as_plugin).to eq('eachValue(matching(type, true))')
      expect(test_class.match_each('some').as_plugin).to eq("eachValue(matching(type, 'some'))")
      expect(test_class.match_each(
        {
          str: test_class.match_any_string('str'),
          bool: test_class.match_any_boolean(true),
          num: test_class.match_any_number(1),
          nested: test_class.match_each(
            {
              a: 1,
              b: '2'
            }
          )
        }
      ).as_plugin).to eq({
                           'pact:match' => "eachValue(matching($'SAMPLE'))",
                           'SAMPLE' => {
                             str: "matching(regex, '(?-mix:.*)', 'str')",
                             bool: 'matching(boolean, true)',
                             num: 'matching(number, 1)',
                             nested: {
                               'pact:match' => "eachValue(matching($'SAMPLE'))",
                               'SAMPLE' => { a: 1, b: '2' }
                             }
                           }
                         })
    end

    it 'properly builds each-key matcher' do
      expect(test_class.match_each_key({ 'some-key' => 'value' },
                                       test_class.match_regex(/\w+-\w+/,
                                                              'some-key')).as_plugin).to eq("eachKey(matching(regex, '(?-mix:\\w+-\\w+)', 'some-key'))") # rubocop:disable Layout/LineLength
      expect(test_class.match_each_key({ 'some-key' => { 'value1' => 1, 'value2' => 2 } },
                                       test_class.match_regex(/\w+-\w+/,
                                                              'some-key')).as_plugin).to eq("eachKey(matching(regex, '(?-mix:\\w+-\\w+)', 'some-key'))") # rubocop:disable Layout/LineLength
    end

    it 'properly builds each-value matcher' do
      expect(test_class.match_each_value(
        {
          str: test_class.match_any_string('str'),
          bool: test_class.match_any_boolean(true),
          num: test_class.match_any_number(1),
          nested: test_class.match_each(
            {
              a: 1,
              b: '2'
            }
          )
        }
      ).as_plugin).to eq({
                           'pact:match' => "eachValue(matching($'SAMPLE'))",
                           'SAMPLE' => {
                             str: "matching(regex, '(?-mix:.*)', 'str')",
                             bool: 'matching(boolean, true)',
                             num: 'matching(number, 1)',
                             nested: {
                               'pact:match' => "eachValue(matching($'SAMPLE'))",
                               'SAMPLE' => { a: 1, b: '2' }
                             }
                           }
                         })
    end

    it 'properly builds semver matcher' do
      expect(test_class.match_semver('1.2.3').as_plugin).to eq("matching(semver, '1.2.3')")
    end

    it 'properly builds content_type matcher' do
      expect(test_class.match_content_type('application/xml',
                                           '<?xml?><test/>').as_plugin).to eq("matching(contentType, 'application/xml', '<?xml?><test/>')") # rubocop:disable Layout/LineLength
    end

    it 'properly builds not_empty matcher' do
      expect(test_class.match_not_empty('some value').as_plugin).to eq("notEmpty('some value')")
    end
  end

  context 'with common regex' do
    it 'has valid regex for iso8601' do
      expect(described_class::ISO8601_REGEX).to match('2020-05-21T16:44:32')
      expect(described_class::ISO8601_REGEX).to match('2020-05-21T16:44:32+10:00')
      expect(described_class::ISO8601_REGEX).to match('2020-05-21T16:44:32.123+10:00')
      expect(described_class::ISO8601_REGEX).to match('2020-05-21T16:44:32.123')
      expect(described_class::ISO8601_REGEX).to match('2020-05-21T16:44:32.123456+10:00')
      expect(described_class::ISO8601_REGEX).to match('2020-05-21T16:44:32.123456')
    end

    it 'has valid regex for UUID' do
      expect(described_class::UUID_REGEX).to match(SecureRandom.uuid)
    end
  end
end
