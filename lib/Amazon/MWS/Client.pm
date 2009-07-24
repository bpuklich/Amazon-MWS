package Amazon::MWS::Client;

use warnings;
use strict;

our $VERSION = '0.1';

use URI;
use XML::Simple;
use HTTP::Request;
use Class::InsideOut qw(:std);
use Digest::MD5 qw(md5_base64);
use Amazon::MWS::TypeMap qw(:all);
use Readonly;

Readonly my $baseEx => 'Amazon::MWS::Client::Exception';

use Exception::Class (
    $baseEx,
    "${baseEx}::MissingArgument" => {
        isa    => $baseEx,
        fields => 'name',
        alias  => 'arg_missing',
    },
    "${baseEx}::Transport" => {
        isa    => $baseEx,
        fields => [qw(request response)],
        alias  => 'transport_error',
    },
    "${baseEx}::Response" => {
        isa    => $baseEx,
        fields => [qw(errors response)],
        alias  => 'error_response',
    },
    "${baseEx}::BadChecksum" => {
        isa    => $baseEx,
        fields => 'request',
        alias  => 'bad_checksum',
    },
);

private agent => my %agent;

sub force_array {
    my ($hash, $key) = @_;
    $hash->{$key} = [ $hash->{$key} ] unless ref $hash->{$key} eq 'ARRAY';
}

sub convert {
    my ($hash, $key, $type) = @_;
    $hash->{key} = from_amazon($type, $hash->{key});
}

sub convert_FeedSubmissionInfo {
    my $root = shift;
    force_array($root, 'FeedSubmissionInfo');

    foreach my $info (@{ $root->{FeedSubmissionInfo} }) {
        convert($info, SubmittedDate => 'datetime');
    }
}

sub slurp_kwargs { ref $_[0] eq 'HASH' ? shift : { @_ } }

sub define_api_method {
    my $method_name = shift;
    my $spec        = slurp_kwargs(@_);
    my $params      = $spec->{parameters};

    my $method = sub {
        my $self = shift;
        my $args = slurp_kwargs(@_);
        my $body;
        my %form = (Action => $method_name);

        foreach my $name (keys %$params) {
            $param = $params->{$name};

            unless (exists $args->{$name}) {
                arg_missing(name => $name) if $param->{required};
                next;
            }

            my $type  = $param->{type};
            my $value = $args->{$name};

            # Odd 'structured list' notation handled here
            if ($type =~ /(\w+)List/) {
                my $list_type = $1;
                my $counter   = 1;
                foreach my $sub_value (@$value) {
                    my $listKey = "$name.$list_type." . $counter++;
                    $form{$listKey} = $sub_value;
                }
                next;
            }

            $value = to_amazon($type, $value);
            if ($type eq 'HTTP-BODY') {
                $body = $value;
            }
            else {
                $form{$name} = $value; 
            }
        }

        my $uri = URI->new($self->endpoint);
        $uri->query_form(\%form);

        my $request = HTTP::Request->new;
        $request->uri($uri);

        if ($body) {
            $request->method('POST'); 
            $request->content($body);
            $request->header('Content-MD5' => md5_base64($body));
            $request->content_type(
        }
        else {
            $request->method('GET');
        }

        $self->set_auth_headers($request);
        my $response = $self->agent->request($request);

        unless ($response->is_success) {
            transport_error(request => $request, response => $response);
        }

        if (my $md5 = $response->header('Content-MD5')) {
            bad_checksum(response => $response) 
                unless ($md5 eq md5_base64($response->content));
        }

        return $response->content if $spec->{raw_body};

        my $xs = XML::Simple->new(
            KeepRoot => 1,
        );
        my $res_hash = $xs->xml_in($response);

        if ($res_hash->{ErrorResponse}) {
            force_array($res_hash, 'Error');
            error_response(errors => $res_hash{Errors}, xml => $response);
        }

        my $root = $res_hash->{$method_name . 'Response'}
            ->{$method_name . 'Result'};

        return $spec->{respond}->($root);
    };

    my $fqn = join '::', __PACKAGE__, $method_name;
    no strict 'refs';
    *$fqn = $method;
}

sub new {
    my $class = shift;
    my $opt   = slurp_kwargs(@_);
    my $self  = register $class;

    my $attr = $opt->{agent_attributes};
    $attr->{language} = 'Perl';

    my $attr_str = join ';', map { "$_=$attr->{$_}" } keys %$attr;
    my $appname  = $opts->{application} || 'Amazon::MWS::Client';
    my $version  = $opts->{version}     || $VERSION;

    $agent{id $self} = LWP::UserAgent->new("$appname/$version ($attr_str)");

    return $self;
}

define_api_method SubmitFeed =>
    parameters => {
        FeedContent => {
            required => 1,
            type     => 'HTTP-BODY',
        },
        FeedType => {
            required => 1,
            type     => 'string',
        },
        PurgeAndReplace => {
            type     => 'boolean',
        },
    },
    respond => sub {
        my $root = shift;
        convert($root, SubmittedDate => 'datetime');
        return $root;
    };

define_api_method GetFeedSubmissionList =>
    parameters => {
        FeedSubmissionIdList     => { type => 'IdList' },
        MaxCount                 => { type => 'nonNegativeInteger' },
        FeedTypeList             => { type => 'TypeList' },
        FeedProcessingStatusList => { type => 'StatusList' },
        SubmittedFromDate        => { type => 'datetime' },
        SubmittedToDate          => { type => 'datetime' },
    },
    respond => sub {
        my $root = shift;
        convert($root, HasNext => 'boolean');
        convert_FeedSubmissionInfo($root);
        return $root;
    };

define_api_method GetFeedSubmissionListByNextToken =>
    parameters => { 
        NextToken => {
            type     => 'string',
            required => 1,
        },
    },
    respond => sub {
        my $root = shift;
        convert($root, HasNext => 'boolean');
        convert_FeedSubmissionInfo($root);

        return $root;
    };

define_api_method GetFeedSubmissionCount =>
    parameters => {
        FeedTypeList             => { type => 'TypeList' },
        FeedProcessingStatusList => { type => 'StatusList' },
        SubmittedFromDate        => { type => 'datetime' },
        SubmittedToDate          => { type => 'datetime' },
    },
    respond => sub { $_[0]->{Count} };

define_api_method CancelFeedSubmissions =>
    parameters => {
        FeedSubmissionIdList => { type => 'IdList' },
        FeedTypeList         => { type => 'TypeList' },
        SubmittedFromDate    => { type => 'datetime' },
        SubmittedToDate      => { type => 'datetime' },
    },
    respond => sub {
        my $root = shift;
        convert_FeedSubmissionInfo($root);
        return $root;
    };

define_api_method GetFeedSubmissionResult =>
    raw_body   => 1,
    parameters => {
        FeedSubmissionId => { 
            type     => 'string',
            required => 1,
        },
    };

define_api_method RequestReport =>
    parameters => {
        ReportType => {
            type     => 'string',
            required => 1,
        }
        StartDate => { type => 'datetime' },
        EndDate   => { type => 'datetime' },
    },
    respond => sub {
        my $root = $_[0]->{RequestReportInfo};

        convert($root, StartDate     => 'datetime');
        convert($root, EndDate       => 'datetime');
        convert($root, Scheduled     => 'boolean');
        convert($root, SubmittedDate => 'datetime');

        return $root;
    };

1;

__END__

=head1 NAME

Amazon::MWS::Client

=head1 DESCRIPTION

An API binding for Amazon's Marketplace Web Services.  An overview of the
entire interface can be found at L<https://mws.amazon.com/docs/devGuide>.

=head1 METHODS

=head2 new

=head1 EXCEPTIONS

Any of the L<API METHODS> can throw the following exceptions
(Exception::Class).  They are all subclasses of Amazon::MWS::Exception.

=head2 Amazon::MWS::Exception::MissingArgument

The call to the API method was missing a required argument.  The name of the
missing argument can be found in $e->name.

=head2 Amazon::MWS::Exception::Transport

There was an error communicating with the Amazon endpoint.  The HTTP::Request
and Response objects can be found in $e->request and $e->response.

=head2 Amazon::MWS::Exception::Response

Amazon returned an response, but indicated an error.  An arrayref of hashrefs
corresponding to the error xml (via XML::Simple on the Error elements) is
available at $e->errors, and the entire xml response is available at $e->xml.

=head2 Amazon::MWS::Exception::BadChecksum

If Amazon sends the 'Content-MD5' header and it does not match the content,
this exception will be thrown.  The response can be found in $e->response.

=head1 API METHODS

The following methods may be called on objects of this class.  All concerns
(such as authentication) which are common to every request are handled by this
class.  

Enumerated values may be specified as strings or as constants from the
Amazon::MWS::Enumeration packages for compile time checking.  

All parameters to individual API methods may be specified either as name-value
pairs in the argument string or as hashrefs, and should have the same names as
specified in the API documentation.  

Return values will be hashrefs with keys as specified in the 'Response
Elements' section of the API documentation unless otherwise noted.

The mapping of API datatypes to perl datatypes is specified in
L<Amazon::MWS::TypeMap>.  Note that where the documentation calls for a
'structured list', you should pass in an arrayref.

=head2 SubmitFeed

=head2 GetFeedSubmissionList

NextToken and HasNext are returned as normal.  FeedSubmissionInfo is an
arrayref containing the other keys for each feed returned.

=head2 GetFeedSubmissionListByNextToken

FeedSubmissionInfo as in GetFeedSubmissionList.

=head2 GetFeedSubmissionCount

Returns the count as a simple scalar.

=head2 CancelFeedSubmissions

FeedSubmissionInfo as in GetFeedSubmissionList.

=head2 GetFeedSubmissionResult

The raw body of the response is returned.  Note: the response will not be
checked for error codes.
