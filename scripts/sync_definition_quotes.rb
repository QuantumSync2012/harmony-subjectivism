#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/concept_quote_gate"

exit ConceptQuoteGate.run(write: ARGV.delete("--write"))
