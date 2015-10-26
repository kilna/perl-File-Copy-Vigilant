package File::Copy::Vigilant;

use warnings;
use strict;

use base qw(Exporter);
our @EXPORT    = qw(copy_vigilant move_vigilant);
our @EXPORT_OK = qw(copy move cp mv);

use File::Copy qw();    # Don't import copy / move into the local namespace
use File::Compare;
use Digest::MD5::File qw(file_md5_hex);

=head1 NAME

File::Copy::Vigilant - Copy and move files with verification and retries

=cut

our $VERSION = '1.2';

=head1 SYNOPSIS

    use File::Copy::Vigilant;

    copy_vigilant( $source, $destination );
    move_vigilant( $source, $destination );

=head1 DESCRIPTION

A module for when your files absolutely, positively have to get there.

By default the copy and move functions will perform MD5 sums on the source
and destination file to ensure that the destination file is exactly the same
as the source file upon completion.  If the copy or move fails for any reason
it will attempt 2 retries by default.

=head1 FUNCTIONS

=head2 copy_vigilant, copy, cp

Copies a file, with post-copy verification and optional retries.  

    copy_vigilant(
        $source, $destination,
        [ check => (checktype), ]
        [ retires => (number of retries), ]
    );

"checktype" is one of the following:

  md5     - Get the MD5 sum of the source before copying, and compare it to
            the MD5 of the destination after copying (default)
  size    - Get the size of the source before copying, and compare it to the
            size of the destination after copying
  compare - Perform a byte-for-byte comparison of the source and destination
            after copying
  none    - Do not perform a check of the source to the destination

"number of retries" is one of the following:

  0          - No retries are performed
  integer    - The number of retries to perform (if a 1 is passed, then the
               copy will be attempted a maximum of 2 times).  Must be a
               positive, whole number.
  'infinite' - The string 'infinite' (and all other strings for that matter)
               will cause it to retry continuously until success

The default is 2 retries (or three attempts total).

If called in a scalar context, it returns 0 for failure or 1 for success.  If
called in a list context, the return value is a 1 or 0, followed by a list of
error messages.

The 'cp' and 'copy' named versions the function are not exported by default,
and you must specify them explicitly to use them:

  use File::Copy::Vigilant qw(cp mv);

  cp( $source, $destination );

Or

  use File::Copy::Vigilant qw(copy move);

  copy( $source, $destination );

=cut

sub copy_vigilant
{

	my ( $source, $dest, %params ) = @_;

	my @errors  = ();
	my $success = eval {

		my $retries = defined( $params{'retries'} ) ? $params{'retries'} : 2;
		if ( $retries !~ m/^\d+$/x )
		{
			$retries = 'infinite';
		}    # Blank = continuous

		my $check
			= defined( $params{'check'} ) ? lc( $params{'check'} ) : 'md5';
		if ( $check !~ m/^md5|size|compare|none$/x ) { $check = 'md5'; }

		# This hook allows us to do some whitebox testing by modifying the
		# results of the copy.  You probably don't want this unless you're
		# testing this module.
		my $postcopy = $params{'_postcopy'};
		if ( defined($postcopy) && ref($postcopy) ne 'CODE' )
		{
			$postcopy = undef;
		}

		my $check_error = _check_files( $source, $dest );
		if ($check_error)
		{
			push @errors, "Pre-copy check failed: $check_error\n";
			return 0;
		}

		my $attempt = 0;
		while ( ( $retries eq 'infinite' ) || ( $attempt++ <= $retries ) )
		{

			my $copy_error = _try_copy( $source, $dest, $check, $postcopy );

			if ($copy_error)
			{
				push @errors, "Copy attempt $attempt failed: $copy_error\n";
			}
			else
			{
				return 1;
			}

		}

		# If we got here, then we looped as many times as
		# we were allowed without a success
		return 0;

	};

	if ($@)
	{
		$success = 0;
		push @errors, "Internal error in copy_vigilant: $@\n";
	}

	return wantarray ? ( $success, @errors ) : $success;

} ## end sub copy_vigilant

# Syntax borrowed from core module File::Copy
sub cp;
*cp = \&copy_vigilant;

sub copy;
*copy = \&copy_vigilant;

sub _check_files
{

	my ( $source, $dest ) = @_;

	if ( ref $source )
	{
		if ( ref($source) eq 'GLOB' ||
			eval { $source->isa('GLOB') } ||
			eval { $source->isa('IO::Handle') } )
		{
			return "can't use filehandle for source";
		}
	}
	elsif ( ref( \$source ) eq 'GLOB' )
	{
		return "can't use filehandle for source";
	}

	if ( ref $dest )
	{
		if ( ref($dest) eq 'GLOB' ||
			eval { $dest->isa('GLOB') } ||
			eval { $dest->isa('IO::Handle') } )
		{
			return "Can't use filehandle for desination";
		}
	}
	elsif ( ref( \$dest ) eq 'GLOB' )
	{
		return "can't use filehandle for destination";
	}

	unless ( stat $source )
	{
		return "unable to stat source file $source";
	}

	if ( -d $source )
	{
		return "unable to copy directory source $source";
	}

	unless ( -f $source || -l $source )
	{
		return "unable to copy non-file source $source";
	}

	# If we got this far then both the source and dest look OK
	return '';
} ## end sub _check_files

sub _try_copy
{

	my ( $source, $dest, $check, $postcopy ) = @_;

	my $source_md5  = undef;
	my $source_size = undef;
	if ( $check eq 'md5' )
	{
		$source_md5 = file_md5_hex($source);
	}
	if ( ( $check eq 'md5' ) || ( $check eq 'size' ) )
	{
		$source_size = ( stat $source )[7];
	}

	unless ( File::Copy::copy( $source, $dest ) )
	{
		return "copy failed: $!";
	}

	defined($postcopy) && $postcopy->(@_);

	my $dest_size = undef;
	if ( $check eq 'md5' || $check eq 'size' )
	{
		$dest_size = ( stat $dest )[7];
	}

	if ( $check eq 'md5' )
	{
		if ( $source_size != $dest_size )
		{
			return "pre-md5 size check failed";
		}
		my $dest_md5 = file_md5_hex($dest);
		if ( $source_md5 ne $dest_md5 )
		{
			return "md5 check failed";
		}
	}
	elsif ( $check eq 'size' )
	{
		if ( $source_size != $dest_size )
		{
			return "size check failed";
		}
	}
	elsif ( $check eq 'compare' )
	{
		if ( File::Compare::compare( $source, $dest ) )
		{
			return "file compare failed";
		}
	}

	# If we got this far then the copy was a success!
	return '';
} ## end sub _try_copy

=head2 move_vigilant, move, mv

The syntax and behavior is exactly the same as copy_vigilant, except it
perfoms an unlink as the last step.

This is terribly inefficient compared to File::Copy's move, which in most
cases is a simple filesystem rename.

'move' and 'mv' are not imported by default, you'll have to add them in
the use syntax (see copy_vigilant for details).

=cut

sub move_vigilant
{

	my ( $source, $dest, %params ) = @_;

	my ( $copy_success, @copy_errors )
	  = copy_vigilant( $source, $dest, %params );

	unless ($copy_success)
	{
		return wantarray ? ( 0, @copy_errors ) : 0;
	}

	my @errors  = ();
	my $success = eval {
		if ( unlink $source )
		{
			return 1;
		}
		else
		{
			push @errors, "Unable to remove source $source "
			  . "(destination file $dest has been left in place)\n";
			return 0;
		}
	};

	if ($@)
	{
		$success = 0;
		push @errors, "Internal error in move_vigilant: $@\n";
	}

	return wantarray ? ( $success, @errors ) : $success;

}

# Syntax borrowed from core module File::Copy
sub mv;
*mv = \&move_vigilant;

sub move;
*move = \&move_vigilant;

=head1 AUTHOR

Anthony Kilna, C<< <anthony at kilna.com> >> - L<http://anthony.kilna.com>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-file-copy-vigilant at rt.cpan.org>,
or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=File-Copy-Vigilant>.
I will be notified, and then you'll automatically be notified
of progress on your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc File::Copy::Vigilant

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=File-Copy-Vigilant>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/File-Copy-Vigilant>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/File-Copy-Vigilant>

=item * Search CPAN

L<http://search.cpan.org/dist/File-Copy-Vigilant>

=back

=head1 SEE ALSO

File::Copy - File::Copy::Reliable

=head1 COPYRIGHT & LICENSE

Copyright 2012 Kilna Companies.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut

1; # End of File::Copy::Vigilant
