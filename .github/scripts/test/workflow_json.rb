require 'json'
require 'yaml'

workflow = YAML.load_file(ARGV.fetch(0))
# Psych's YAML 1.1 parser treats GitHub's `on` key as a boolean.
workflow['on'] = workflow.delete(true) if workflow.key?(true)
puts JSON.generate(workflow)
