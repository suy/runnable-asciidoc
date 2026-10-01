.PHONY: test example clean

test:
	GEM_HOME=$(GEM_HOME) ruby test/auto/run.rb

# Convert the example document and check it.
example:
	GEM_HOME=$(GEM_HOME) bin/runnable-asciidoc -o /tmp/setup-guide.sh examples/setup-guide.adoc
	bash -n /tmp/setup-guide.sh

clean:
	rm -f /tmp/setup-guide.sh
