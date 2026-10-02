# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Alejandro Exojo Piqueras
#
# End-to-end tests for the runnable-asciidoc backend: convert example
# documents, syntax-check the generated scripts, and drive them.
#
# Run with: ruby test/auto/run.rb (minitest ships with Ruby; no gems needed)

require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'fileutils'

PROJECT = File.expand_path('../..', __dir__)
LIB = File.join(PROJECT, 'lib', 'runnable-asciidoc.rb')

require 'asciidoctor' unless defined?(Asciidoctor)
require LIB

# Converts an AsciiDoc string through the runnable backend. Returns the
# generated script path; the sandbox directory stays in @dir and is
# removed when the test process exits.
def convert(adoc, name = 'doc.adoc')
  @dir = Dir.mktmpdir
  Minitest.after_run { FileUtils.remove_entry(@dir) if File.exist?(@dir) }
  source = File.join(@dir, name)
  File.write(source, adoc)
  script = File.join(@dir, "#{File.basename(name, '.adoc')}.sh")
  _out, error, status = Open3.capture3(
    { 'GEM_HOME' => ENV['GEM_HOME'] }.compact,
    'ruby', '-I', File.dirname(LIB), '-rasciidoctor',
    '-r', LIB, '-e',
    "Asciidoctor.convert_file #{source.inspect}, " \
    "backend: 'runnable', safe: :unsafe, to_file: #{script.inspect}, mkdirs: true"
  )
  flunk "conversion failed:\n#{error}" unless status.success?
  script
end

# Runs the generated script with the given stdin, returns [stdout, status].
def run_script(script, stdin: '', args: [])
  out, status = Open3.capture2e({ 'HOME' => Dir.tmpdir }, 'bash', script, *args, stdin_data: stdin)
  [out, status]
end

class ShellQuotingTest < Minitest::Test
  def test_plain_text
    assert_equal "'hello'", RunnableAsciidoc.shell_single_quoted('hello')
  end

  def test_text_with_apostrophe
    quoted = RunnableAsciidoc.shell_single_quoted("it's")
    assert_equal "'it'\\''s'", quoted
  end

  def test_quoted_text_survives_bash
    text = "dona's \"tricky\" $HOME `pwd` \\ line"
    script = "printf '%s\\n' #{RunnableAsciidoc.shell_single_quoted(text)}\n"
    out = IO.popen(['bash', '-c', script], &:read)
    assert_equal text, out.chomp
  end

  def test_print_call_lines_are_printed
    # Every context line must appear inside a runnable_print* call; a bare
    # newline inside a function body prints nothing, which once silently
    # swallowed all paragraph breaks.
    text = 'a line'
    script = <<~SH
      runnable_print() { printf '%s\\n' "$1"; }
      runnable_print #{RunnableAsciidoc.shell_single_quoted(text)}
    SH
    out = IO.popen(['bash', '-c', script], &:read)
    assert_equal "a line\n", out
  end

  def test_block_function_name_padding
    assert_equal 'block_01', RunnableAsciidoc.block_function_name(1)
    assert_equal 'block_12', RunnableAsciidoc.block_function_name(12)
  end

  def test_wrap_text_preserves_paragraph_breaks
    lines = RunnableAsciidoc.wrap_text("one two\n\nthree", 40)
    assert_equal ['one two', '', 'three'], lines
  end

  def test_wrap_text_long_word_kept_intact
    lines = RunnableAsciidoc.wrap_text('x' * 50, 10)
    assert_equal ['x' * 50], lines
  end

  def test_wrap_text_greedy_fill
    lines = RunnableAsciidoc.wrap_text('aa bb cc dd', 6)
    assert_equal ['aa bb', 'cc dd'], lines
  end
end

class ConversionTest < Minitest::Test
  SAMPLE = <<~ADOC
    = Sample
    :project: xyz

    Intro prose with *bold*, `code`, and a link:https://example.org[site].

    == First

    Before text.

    [source,bash]
    ----
    echo one
    ----

    == Second

    [source,bash,opts=norun]
    ----
    echo not-run
    ----

    [source,python]
    ----
    print("py")
    ----

    ----
    unlabeled
    ----

    [source,bash]
    ----
    echo two
    ----

    Closing prose.
  ADOC

  def setup
    @script = convert SAMPLE
  end

  def test_generated_script_is_valid_bash
    _out, status = Open3.capture2e('bash', '-n', @script)
    assert status.success?
  end

  def test_two_runnable_blocks
    out, _status = run_script @script, args: ['--list']
    assert_includes out, 'block_01: echo one'
    assert_includes out, 'block_02: echo two'
    refute_includes out, 'not-run'
  end

  def test_norun_and_foreign_blocks_are_context_only
    File.write(@script, File.read(@script)) # no-op, keep path stable
    content = File.read(@script)
    assert_includes content, 'echo not-run'
    assert_includes content, '(python, not run)'
    assert_includes content, 'unlabeled'
    refute_includes content, 'block_03()'
  end

  def test_prose_markup_expanded
    content = File.read(@script)
    assert_includes content, 'Intro prose with bold, code, and a site (https://example.org).'
  end

  def test_paragraph_breaks_print_blank_lines
    out, _status = run_script @script, args: ['--yes']
    assert_includes out, "Intro prose with bold, code, and a site (https://example.org).\n\n"
  end

  def test_no_prose_hides_prose_but_keeps_headings_and_code
    out, status = run_script @script, args: ['--yes', '--no-prose']
    assert status.success?
    refute_includes out, 'Before text.'
    refute_includes out, 'Closing prose.'
    assert_includes out, '=== Sample ==='
    assert_includes out, '== First'
    assert_includes out, '== Second'
    assert_includes out, 'echo one'
    assert_includes out, 'echo two'
    assert_includes out, '(python, not run)'
  end

  def test_no_prose_flag_combines_and_rejects_unknown_flags
    _out, status = run_script @script, args: ['--no-prose', '--yes']
    assert status.success?
    _out, status = run_script @script, args: ['--bogus']
    refute status.success?
  end

  def test_code_block_title_is_printed
    doc = <<~ADOC
      = Titled

      [source,bash]
      .Build the demo
      ----
      echo one
      ----
    ADOC
    script = convert doc
    content = File.read(script)
    assert_includes content, "runnable_print 'Build the demo'"
    out, _status = run_script script, args: ['--yes', '--no-prose']
    assert_includes out, 'Build the demo'
  end

  def test_titled_block_hint_prefers_title
    doc = <<~ADOC
      = Titled

      [source,bash]
      .Build the demo
      ----
      echo one
      ----
    ADOC
    script = convert doc
    out, _status = run_script script, args: ['--list']
    assert_includes out, 'block_01: Build the demo'
  end

  def test_block_source_is_echoed_before_running
    out, _status = run_script @script, args: ['--yes']
    # The whole code, indented, shows before the block output.
    assert_match(/\+ block 1\/2.*\n    echo one\none\n/, out)
  end

  def test_multiline_block_source_is_echoed_verbatim
    doc = <<~ADOC
      = Multi

      [source,bash]
      ----
      printf '%s\\n' 'it''s $tricky'
      echo done
      ----
    ADOC
    script = convert doc
    content = File.read(script)
    assert_includes content, "runnable_print_code 'echo done'"
    out, _status = run_script script, args: ['--yes']
    assert_includes out, "    echo done\n"
  end

  def test_full_run_and_resume
    out, status = run_script @script, stdin: "\n\n"
    assert status.success?
    assert_includes out, 'one'
    assert_includes out, 'two'
    assert_includes out, 'All blocks handled.'
    progress = File.read(File.join(@dir, 'doc.sh.progress'))
    assert_match(/^block_01 done$/, progress)
    assert_match(/^block_02 done$/, progress)
  end

  def test_failure_stops_and_resume_continues
    failing = SAMPLE.sub('echo one', 'false')
    script = convert failing
    dir = @dir
    out, _status = run_script script, stdin: "\n\n"
    assert_includes out, 'Block failed with exit status 1.'
    progress = File.read(File.join(dir, 'doc.sh.progress'))
    assert_match(/^block_01 failed$/, progress)

    # Second run: skipping the failed block records it as skipped.
    out, _status = run_script script, stdin: "s\n\n"
    assert_includes out, 'All blocks handled.'
    progress = File.read(File.join(dir, 'doc.sh.progress'))
    assert_match(/^block_01 skipped$/, progress)
    assert_match(/^block_02 done$/, progress)
  end

  def test_yes_flag_is_noninteractive
    out, _status = run_script @script, stdin: '', args: ['--yes']
    assert_includes out, 'All blocks handled.'
    refute_includes out, '[Enter]'
  end

  def test_reset_flag_clears_progress
    run_script @script, stdin: "\n\n"
    _out, status = run_script @script, args: ['--reset']
    assert status.success?
    refute_path_exists File.join(@dir, 'doc.sh.progress')
  end

  def test_quitting_midway_saves_progress
    out, _status = run_script @script, stdin: "\nq\n"
    assert_includes out, 'Stopped'
    progress = File.read(File.join(@dir, 'doc.sh.progress'))
    assert_match(/^block_01 done$/, progress)
    refute_match(/^block_02/, progress)
  end

  def test_resume_skips_done_blocks
    run_script @script, stdin: "\nq\n"
    out, _status = run_script @script, stdin: "\n"
    refute_includes out, 'echo one'
    assert_includes out, 'echo two'
    assert_includes out, 'All blocks handled.'
  end

  def test_progress_file_survives_cd_in_blocks
    doc = <<~ADOC
      = Chdir

      [source,bash]
      ----
      mkdir -p sub
      cd sub
      ----
      [source,bash]
      ----
      pwd
      ----
    ADOC
    script = convert doc
    dir = @dir
    run_script script, stdin: "\n\n"
    assert_path_exists File.join(dir, 'doc.sh.progress')
  end

  def test_document_with_no_runnable_blocks
    doc = <<~ADOC
      = Nothing
      Just prose.
    ADOC
    script = convert doc
    _out, status = Open3.capture2e('bash', '-n', script)
    assert status.success?
    out, status = run_script script
    assert status.success?
    assert_includes out, 'no runnable blocks'
  end

  def test_example_document_round_trip
    example = File.join(PROJECT, 'examples', 'setup-guide.adoc')
    script = convert File.read(example), 'setup-guide.adoc'
    _out, status = Open3.capture2e('bash', '-n', script)
    assert status.success?
  end
end
