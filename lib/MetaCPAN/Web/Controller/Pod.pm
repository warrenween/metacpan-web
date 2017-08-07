package MetaCPAN::Web::Controller::Pod;

use HTML::Restrict;
use Moose;
use Try::Tiny;
use URI;
use HTML::Escape qw(escape_html);

use namespace::autoclean;

BEGIN { extends 'MetaCPAN::Web::Controller' }

# /pod/$name
sub find : Path : Args(1) {
    my ( $self, $c, @path ) = @_;

    $c->browser_max_age('1h');

    # TODO: Pass size param so we can disambiguate?
    my $pod_file = $c->stash->{pod_file}
        = $c->model('API::Module')->find(@path)->get;

    $c->detach('/not_found')
        if !$pod_file->{name};

    my $release_info
        = $c->model('ReleaseInfo')
        ->get( $pod_file->{author}, $pod_file->{release} )
        ->else( sub { Future->done( {} ) } );
    $c->stash( $release_info->get );

    # TODO: Disambiguate if there's more than once match. #176

    $c->forward( 'view', [@path] );
}

# /pod/release/$AUTHOR/$release/@path
sub release : Local : Args {
    my ( $self, $c, $author, $release, @path ) = @_;

    if ( !@path ) {
        $c->detach('/not_found');
    }
    $c->browser_max_age('1d');

    # force consistent casing in URLs
    if ( $author ne uc $author ) {
        $c->res->redirect(
            $c->uri_for( $c->action, uc $author, $release, @path ), 301 );
        $c->detach();
    }

    my $release_data
        = $c->model('ReleaseInfo')->get( $author, $release )->else_done( {} );
    my $pod_file = $c->model('API::Module')->get( $author, $release, @path );
    $c->stash(
        {
            pod_file => $pod_file->get,
            %{ $release_data->get },
            permalinks => 1,
        }
    );

    $c->forward( 'view', [ $author, $release, @path ] );
}

# /pod/distribution/$name/@path
sub distribution : Local : Args {
    my ( $self, $c, $dist, @path ) = @_;

    $c->browser_max_age('1h');

# TODO: Could we do this with one query?
# filter => { path => join('/', @path), distribution => $dist, status => latest }

    # Get latest "author/release" of dist so we can use it to find the file.
    # TODO: Pass size param so we can disambiguate?
    my $release_data = try {
        $c->model('ReleaseInfo')->find($dist)->get;
    } or $c->detach('/not_found');

    unshift @path, @{ $release_data->{release} }{qw( author name )};

    $c->stash(
        {
            %$release_data,
            pod_file => $c->model('API::Module')->get(@path)->get,
        }
    );

    $c->forward( 'view', [@path] );
}

sub view : Private {
    my ( $self, $c, @path ) = @_;

    my $data       = $c->stash->{pod_file};
    my $permalinks = $c->stash->{permalinks};

    if ( $data->{directory} ) {
        $c->res->redirect( $c->uri_for( '/source', @path ), 301 );
        $c->detach;
    }

    my ( $documentation, $assoc_pod, $documented_module )
        = map { $_->{name}, $_->{associated_pod}, $_ }
        grep { @path > 1 || $path[0] eq $_->{name} }
        grep {
              !$data->{documentation}
            || $data->{documentation} eq $_->{name}
        }
        grep { $_->{associated_pod} } @{ $data->{module} || [] };

    $data->{documentation} = $documentation if $documentation;

    if (   $assoc_pod
        && $assoc_pod ne "$data->{author}/$data->{release}/$data->{path}" )
    {
        $data->{pod_path}
            = $assoc_pod =~ s{^\Q$data->{author}/$data->{release}/}{}r;
    }

    $c->detach('/not_found') unless ( $data->{name} );

    my $pod_path = '/pod/' . ( $assoc_pod || join( q{/}, @path ) );

    my $pod = $c->model('API')->request(
        $pod_path,
        undef,
        {
            show_errors => 1,
            ( $permalinks ? ( permalinks => 1 ) : () ),
            url_prefix => '/pod/',
        }
    )->get;

    my $pod_html = $self->filter_html( $pod->{raw}, $data );

    my $release = $c->stash->{release};

    #<<<
    my $canonical = ( $documented_module
            && $documented_module->{authorized}
            && $documented_module->{indexed}
        ) ? "/pod/$documentation"
        : join(q{/}, q{}, qw( pod distribution ), $release->{distribution},
            # Strip $author/$release from front of path.
            @path[ 2 .. $#path ]
        );
    #>>>

    # Store at fastly for a year - as we will purge!
    $c->cdn_max_age('1y');
    $c->add_dist_key( $release->{distribution} );
    $c->add_author_key( $release->{author} );

    $c->stash(
        {
            template          => 'pod.html',
            module            => $data,
            pod               => $pod_html,
            canonical         => $canonical,
            documented_module => $documented_module,
        }
    );

    unless ( $pod->{raw} ) {
        $c->stash( pod_error => $pod->{message}, );
    }
}

sub filter_html {
    my ( $self, $html, $data ) = @_;

    my $hr = HTML::Restrict->new(
        uri_schemes =>
            [ undef, 'http', 'https', 'data', 'mailto', 'irc', 'ircs' ],
        rules => {
            a       => [qw( href id target )],
            b       => [],
            br      => [],
            caption => [],
            center  => [],
            code    => [ { class => qr/^language-\S+$/ } ],
            dd      => [],
            div     => [ { class => qr/^pod-errors(?:-detail)?$/ } ],
            dl      => [],
            dt      => ['id'],
            em      => [],
            h1      => ['id'],
            h2      => ['id'],
            h3      => ['id'],
            h4      => ['id'],
            h5      => ['id'],
            h6      => ['id'],
            i       => [],
            li      => ['id'],
            ol      => [],
            p       => [],
            pre     => [
                {
                    class        => qr/^line-numbers$/,
                    'data-line'  => qr/^\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*$/,
                    'data-start' => qr/^\d+$/,
                }
            ],
            span   => [ { style => qr/^white-space: nowrap;$/ } ],
            strong => [],
            sub    => [],
            sup    => [],
            table => [ qw( border cellspacing cellpadding align ), ],
            tbody => [],
            th    => [],
            td    => [],
            tr    => [],
            u     => [],
            ul    => [ { id => qr/^index$/ } ],
        },
        replace_img => sub {

            # last arg is $text, which we don't need
            my ( $tagname, $attrs, undef ) = @_;
            my $tag = '<img';
            for my $attr (qw( alt border height width src title)) {
                next
                    unless exists $attrs->{$attr};
                my $val = $attrs->{$attr};
                if ( $attr eq 'src' ) {
                    if ( $val =~ m{^(?:(?:https?|ftp):)?//|^data:} ) {

                        # use directly
                    }
                    elsif ( $val =~ /^[0-9a-zA-Z.+-]+:/ ) {

                        # bad protocol
                        return '';
                    }
                    else {
                        my $base = "https://st.aticpan.org/source/";
                        if ( $val =~ s{^/}{} ) {
                            $base .= "$data->{author}/$data->{release}/";
                        }
                        else {
                            $base .= $data->{associated_pod}
                                || "$data->{author}/$data->{release}/$data->{path}";
                        }
                        $val = URI->new_abs( $val, $base )->as_string;
                    }
                }
                $tag .= qq{ $attr="} . escape_html($val) . qq{"};
            }
            $tag .= ' />';
            return $tag;
        },
    );
    $hr->process($html);
}

__PACKAGE__->meta->make_immutable;

1;
