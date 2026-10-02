.PHONY: test example example-json clean

test:
	GEM_HOME=$(GEM_HOME) ruby test/auto/run.rb

# Convert the example document and check it.
example:
	GEM_HOME=$(GEM_HOME) bin/runnable-asciidoc -o /tmp/setup-guide.sh examples/setup-guide.adoc
	bash -n /tmp/setup-guide.sh

# Convert the example document to JSON and check it.
example-json:
	GEM_HOME=$(GEM_HOME) bin/runnable-asciidoc -b runnable-json -o /tmp/setup-guide.json examples/setup-guide.adoc
	ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))' /tmp/setup-guide.json

clean:
	rm -f /tmp/setup-guide.sh /tmp/setup-guide.sh.progress /tmp/setup-guide.json
