#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Basename qw(dirname);

my ($infile, $top, $outfile, $hierfile, $help);
my @incdirs;
$outfile  = 'extracted.sv';
$hierfile = 'hierarchy.txt';

GetOptions(
  'in=s'      => \$infile,
  'top=s'     => \$top,
  'out=s'     => \$outfile,
  'hier=s'    => \$hierfile,
  'incdir=s@' => \@incdirs,
  'help'      => \$help,
) or die usage();

die usage() if $help;
die "ERROR: --in is required\n"  unless $infile;
die "ERROR: --top is required\n" unless $top;

my $text = slurp($infile);
@incdirs = map { split /,/, $_ } @incdirs;

# 1) 抽取 module 块
my %module_body = parse_modules_only($text);
my @module_ranges = parse_module_ranges($text);

die "ERROR: top module '$top' not found in $infile\n" unless exists $module_body{$top};

# 3) 建依赖图（parent -> child modules）
my %missing_modules;
my %graph;
for my $m (keys %module_body) {
  $graph{$m} = [ extract_children($module_body{$m}, \%module_body, \%missing_modules) ];
}

# 4) 从 top 做闭包
my %seen;
my @q = ($top);
while (@q) {
  my $m = shift @q;
  next if $seen{$m}++;
  for my $c (@{ $graph{$m} || [] }) {
    push @q, $c unless $seen{$c};
  }
}

my @needed = sort keys %seen;

# 5) 输出 hierarchy
my $hier = gen_hierarchy($top, \%graph);
spit($hierfile, $hier);

# 6) 输出 extracted.sv（按原文件顺序输出，保持指令作用域）
my @ordered = modules_in_source_order(\@module_ranges, \%seen);
my @out = build_output_with_scoped_directives($text, \@module_ranges, \%seen, $infile, $top);
spit($outfile, join("\n", @out));

# 输出缺失的外部模块
if (keys %missing_modules) {
  my @missing_list = sort keys %missing_modules;
  spit('missing_modules.txt', join("\n", @missing_list) . "\n");
}

# 7) 复制被抽取模块里用到的 include 文件（递归）
my $out_incdir = out_incdir_from_outfile($outfile);
my %include_state = (seen => {}, copied => {});
my $selected_text = join("\n\n", @out);
copy_includes_recursive($selected_text, dirname_abs($infile), \@incdirs, $out_incdir, \%include_state);

print "Done\n";
print "  input      : $infile\n";
print "  top        : $top\n";
print "  modules    : " . scalar(@needed) . " (" . join(', ', @ordered) . ")\n";
print "  output sv  : $outfile\n";
print "  hierarchy  : $hierfile\n";
print "  include dir: $out_incdir (copied " . scalar(keys %{ $include_state{copied} }) . ")\n";
if (keys %missing_modules) {
  my @missing_list = sort keys %missing_modules;
  print "  missing mod: " . scalar(@missing_list) . " (" . join(', ', @missing_list) . ")\n";
}

sub usage {
  return <<'USAGE';
Usage:
  perl svslice_simple.pl --in design.sv --top top_module [--out extracted.sv] [--hier hierarchy.txt] [--incdir dir]

Input:
  --in      单个 .v/.sv 文件（可包含多个module）
  --top     需要抽取的顶层module名
  --incdir  include搜索路径（可重复）

Output:
  --out     抽取后的合并文件（默认 extracted.sv）
  --hier    层级关系文本（默认 hierarchy.txt）
  并自动复制被抽取模块用到的 `include 文件到 <out目录>/include
USAGE
}

sub parse_modules_only {
  my ($txt) = @_;
  my %mods;
  while ($txt =~ /(^\s*module\s+([A-Za-z_]\w*)\b[\s\S]*?^\s*endmodule\b\s*$)/mg) {
    my ($chunk, $name) = ($1, $2);
    $mods{$name} = $chunk;
  }
  return %mods;
}

sub parse_module_ranges {
  my ($txt) = @_;
  my @lines = split /\n/, $txt, -1;
  my @line_start;
  my $pos = 0;
  for my $ln (@lines) {
    push @line_start, $pos;
    $pos += length($ln) + 1;
  }

  my @ranges;
  while ($txt =~ /(^\s*module\s+([A-Za-z_]\w*)\b[\s\S]*?^\s*endmodule\b\s*$)/mg) {
    my ($chunk, $name) = ($1, $2);
    my $start_pos = $-[1];
    my $end_pos   = $+[1];

    my $start_line = 1;
    my $end_line   = scalar(@lines);
    for (my $i = 0; $i < @line_start; $i++) {
      if ($line_start[$i] <= $start_pos) { $start_line = $i + 1; }
      else { last; }
    }
    for (my $i = 0; $i < @line_start; $i++) {
      if ($line_start[$i] < $end_pos) { $end_line = $i + 1; }
      else { last; }
    }

    push @ranges, {
      name  => $name,
      start => $start_line,
      end   => $end_line,
      body  => $chunk,
    };
  }

  @ranges = sort { $a->{start} <=> $b->{start} } @ranges;
  return @ranges;
}

sub modules_in_source_order {
  my ($ranges_ref, $need_ref) = @_;
  my @out;
  for my $r (@$ranges_ref) {
    push @out, $r->{name} if $need_ref->{ $r->{name} };
  }
  return @out;
}

sub is_directive_line {
  my ($l) = @_;
  return ($l =~ /^\s*`(?:timescale|include|define|undef|celldefine|endcelldefine|default_nettype|resetall|unconnected_drive|nounconnected_drive|line|pragma)\b/) ? 1 : 0;
}

sub build_output_with_scoped_directives {
  my ($txt, $ranges_ref, $need_ref, $infile, $top) = @_;
  my @lines = split /\n/, $txt, -1;

  my @out;
  push @out, "// Auto-generated from: $infile";
  push @out, "// Top module: $top";
  push @out, "";

  my %start_to_range = map { $_->{start} => $_ } @$ranges_ref;
  my @pending_directives;

  my $line = 1;
  while ($line <= scalar(@lines)) {
    if (exists $start_to_range{$line}) {
      my $r = $start_to_range{$line};
      my $name = $r->{name};
      my $is_needed = $need_ref->{$name};

      if ($is_needed) {
        push @out, "// ===== module: $name =====";
        if (@pending_directives) {
          push @out, @pending_directives;
          push @out, "";
        }
        for my $ln ($r->{start} .. $r->{end}) {
          push @out, $lines[$ln - 1];
        }
        push @out, "";
        @pending_directives = ();
      }

      $line = $r->{end} + 1;
      next;
    }

    my $l = $lines[$line - 1];
    push @pending_directives, $l if is_directive_line($l);
    $line++;
  }

  return @out;
}

sub extract_children {
  my ($body, $modref, $missing_ref) = @_;
  my @c;

  my %kw = map { $_ => 1 } qw(
    if else for while begin end case casex casez assign always initial
    wire reg logic input output inout parameter localparam generate endgenerate
    module endmodule function endfunction task endtask typedef struct enum
    package endpackage interface endinterface class endclass virtual
  );

  for my $line (split /\n/, $body) {
    $line =~ s{//.*$}{};
    next if $line =~ /^\s*`/;

    # child #(....) u_xxx (...);
    # child u_xxx (...);
    if ($line =~ /^\s*([A-Za-z_]\w*)\s*(?:#\s*\()?/) {
      my $cand = $1;
      next if $kw{$cand};
      next unless $line =~ /\(/;
      
      if (exists $modref->{$cand}) {
        push @c, $cand;
      } elsif ($missing_ref) {
        # 记录缺失的模块（只记一次）
        $missing_ref->{$cand} = 1;
      }
    }
  }
  return uniq(@c);
}

sub gen_hierarchy {
  my ($top, $graph) = @_;
  my @out;
  my %path;
  my $walk;

  $walk = sub {
    my ($m, $d) = @_;
    push @out, ('  ' x $d) . "- $m";

    if ($path{$m}) {
      push @out, ('  ' x ($d+1)) . "[cycle]";
      return;
    }

    $path{$m} = 1;
    for my $c (sort @{ $graph->{$m} || [] }) {
      $walk->($c, $d + 1);
    }
    delete $path{$m};
  };

  $walk->($top, 0);
  return join("\n", @out) . "\n";
}

sub topo_like_order {
  my ($top, $graph, $need) = @_;
  my @out;
  my %visited;

  my $dfs;
  $dfs = sub {
    my ($m) = @_;
    return if $visited{$m}++;
    for my $c (@{ $graph->{$m} || [] }) {
      next unless $need->{$c};
      $dfs->($c);
    }
    push @out, $m; # child first, parent later
  };

  $dfs->($top);
  return @out;
}

sub copy_includes_recursive {
  my ($txt, $src_dir, $incdirs_ref, $out_incdir, $state_ref) = @_;
  make_path($out_incdir) unless -d $out_incdir;

  while ($txt =~ /^\s*`include\s+"([^"]+)"/mg) {
    my $inc = $1;
    next if $state_ref->{seen}{$inc}++;

    my $resolved = resolve_include($inc, $src_dir, $incdirs_ref);
    next unless defined $resolved;

    my $dst = "$out_incdir/$inc";
    my $dst_dir = dirname($dst);
    make_path($dst_dir) unless -d $dst_dir;
    copy($resolved, $dst) or warn "WARN: failed to copy include $resolved -> $dst: $!\n";
    $state_ref->{copied}{$inc} = 1 if -f $dst;

    my $inc_txt = slurp($resolved);
    my $next_src = dirname($resolved);
    copy_includes_recursive($inc_txt, $next_src, $incdirs_ref, $out_incdir, $state_ref);
  }
}

sub resolve_include {
  my ($inc, $src_dir, $incdirs_ref) = @_;
  my @cands = ("$src_dir/$inc", map { "$_/$inc" } @$incdirs_ref);
  for my $p (@cands) {
    return $p if -f $p;
  }
  return undef;
}

sub out_incdir_from_outfile {
  my ($outfile) = @_;
  my $d = dirname($outfile);
  $d = '.' if !defined($d) || $d eq '';
  return "$d/include";
}

sub dirname_abs {
  my ($p) = @_;
  my $d = dirname($p);
  $d = '.' if !defined($d) || $d eq '';
  return $d;
}

sub uniq {
  my %h;
  grep { !$h{$_}++ } @_;
}

sub slurp {
  my ($f) = @_;
  open my $fh, '<', $f or die "ERROR: cannot open $f: $!\n";
  local $/ = undef;
  my $s = <$fh>;
  close $fh;
  return $s;
}

sub spit {
  my ($f, $s) = @_;
  my $d = dirname($f);
  make_path($d) if defined($d) && $d ne '' && $d ne '.' && !-d $d;
  open my $fh, '>', $f or die "ERROR: cannot write $f: $!\n";
  print {$fh} $s;
  close $fh;
}
