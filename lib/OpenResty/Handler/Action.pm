package OpenResty::Handler::Action;

#use Smart::Comments '####';
use strict;
use warnings;

use OpenResty::Util;
use Params::Util qw( _HASH _STRING );
use OpenResty::RestyScript;
use OpenResty::Limits;
use JSON::XS;
use Data::Dumper qw(Dumper);
use OpenResty::QuasiQuote::SQL;

use base 'OpenResty::Handler::Base';

__PACKAGE__->register('action');

sub level2name {
    qw< action_list action action_param action_exec  >[$_[-1]]
}

my $json = JSON::XS->new->utf8;

sub POST_action_exec {
    my ( $self, $openresty, $bits ) = @_;
    my $action = $bits->[1];

    # Process builtin actions
    my $meth = "exec_$action";
    if ( $self->can($meth) ) {
        return $self->$meth($openresty);
    }

    # Get parameters from POST body content
    my $args = $openresty->{_req_data};
    die "Invalid POST body content, must be a JSON object"
        unless _HASH($args);
    my $url_params = $openresty->{_url_params};
    $args = Hash::Merge::merge($args, $url_params);

    # Complement parameter values from URL
    # Execute action
    return $self->exec_user_action( $openresty, $action, $args );
}

# Remove all existing actions for current user (not including builtin actions)
sub DELETE_action_list {
    my ( $self, $openresty, $bits ) = @_;

    # Try to remove all action parameters
    $openresty->do("delete from _action_params; delete from _actions");
    # All actions except builtin ones were removed successfully
    return {
        success => 1,
        warning => 'Builtin actions were skipped.',
    };
}

# List all existing actions for current user (including builtin actions)
sub GET_action_list {
    my ( $self, $openresty, $bits ) = @_;
    my $sql = [:sql|
        select name, description
        from _actions |];
    my $actions = $openresty->select( $sql, { use_hash => 1 } );

    # Prepend builtin actions
    unshift @$actions,
        { name => 'RunView',   description => 'View interpreter' },
        { name => 'RunAction', description => 'Action interpreter' };

    # Add src property for each action entry
    map { $_->{src} = "/=/action/$_->{name}" } @$actions;
    $actions;
}

# List the details of action with the given name, if the given action name is '~' then
# list all existing actions for current user by using GET_action_list.
sub GET_action {
    my ( $self, $openresty, $bits ) = @_;
    my $act_name = $bits->[1];

# If the given action name is wildcard ('~'), then forward the request to GET_action_list
    if ( $act_name eq '~' ) {
        my $act_lst = $self->GET_action_list( $openresty, $bits );
        return $act_lst;
    }

    # Retrieve the corresponding action information
    my ( $sql, $res );
    $sql = [:sql|
        select id, name, description, definition
        from _actions
        where name = $act_name |];
    $res = $openresty->select( $sql, { use_hash => 1 } );
    if ( !$res || @$res == 0 ) {
        die "Action \"$act_name\" not found.\n";
    }

    # Retrieve the action parameter information
    my $act_info = $res->[0];
    my $id = $act_info->{id};
    $sql = [:sql|
        select name, type, label, default_value
        from _action_params
        where action_id = $id and used = true |];
    $res = $openresty->select( $sql, { use_hash => 1 } );

    # Rename the field "default_value" to "default" and remove field "id"
    $act_info->{parameters} = $res;
    delete $act_info->{id};

    $act_info;
}

# Execute the given action, possibly with parameters
sub GET_action_exec {
    my ( $self, $openresty, $bits ) = @_;
    my $args = $openresty->{_url_params};
    if ($bits->[2] ne '~' && $bits->[3] ne '~') {
        $args->{$bits->[2]} = $bits->[3];
    }
    #### $args
    return $self->exec_user_action( $openresty, $bits->[1], $args );

}

sub join_frags_with_args {
    my ( $frags, $var_map ) = @_;
    my $result;
    my $ref = ref($frags);

    if ($ref) {
        die "Unknown fragments reference type \"$ref\""
            unless ( $ref eq 'ARRAY' );

        # Given command fragments, proceeding with variable substitution
        for my $frag (@$frags) {
            my $frag_ref = ref($frag);

            if ($frag_ref) {

                # Variable fragment encountered
                die
                    "Parameter fragment reference type should be \"ARRAY\": currently \"$frag_ref\""
                    unless ( $frag_ref eq 'ARRAY' );

                my ( $name, $type ) = @$frag;
                die "Required parameter \"$name\" not assigned"
                    unless ( exists( $var_map->{$name} ) );

                $type = lc($type);
                if ( $type eq 'quoted' ) {

                    # Param should be interpolated as a quoted string
                    $result .= Q( $var_map->{$name} );
                } elsif ( $type eq 'literal' || $type eq 'keyword' ) {

                    # Param should be interpolated as a literal
                    $result .= $var_map->{$name};
                } elsif ( $type eq 'symbol' ) {

                    # Param should be treated like a symbol
                    $result .= QI( $var_map->{$name} );
                } else {

          # Unrecognized param type, coerced to interpolate as a quoted string
                    $result .= Q( $var_map->{$name} );
                }

            } else {

                # Literal fragment encountered
                $result .= $frag;
            }
        }
    } else {

        # Given a solid string, no more works to do
        $result = $frags;
    }

    return $result;
}

sub exec_user_action {
    my ( $self, $openresty, $action, $args ) = @_;
    my $i = 0;

    if ( $action eq '~' ) {
        die "Action name must be specified before executing.";
    }


    my $sql = [:sql|
        select compiled
        from _actions
        where name = $action |];
    my $res = $openresty->select( $sql );
    if ( !$res || @$res == 0 ) {
        die "Action \"$action\" not found.\n";
    }

    my $compiled = $res->[0][0];
    eval { $compiled = $OpenResty::JsonXs->decode($compiled); };
    if ($@) {
        die "Failed to load compiled fragments for action \"$action\".\n";
    }
    my ($params, $canon_cmds) = @$compiled;

    while (my ($name, $param) = each %$params) {
        my $val = $args->{ $name };
        if ( !defined $val && !defined $param->{default_value} ) {
            # Some parameter were not given
            die "Parameter \"$name\" were not given, and no default value was set.\n";
        }
        $args->{ $name } = $val || $param->{default_value};
    }

    my @outputs;
    for my $cmd (@$canon_cmds) {
        $i++;
        if ( !ref( $cmd->[0] ) ) {    # being an HTTP method
            my ( $http_meth, $url, $content ) = @$cmd;

            # Proceeds variable value substitutions
            $url     = join_frags_with_args( $url, $args );
            $content = join_frags_with_args( $content, $args );

  # DO NOT permit cross-domain HTTP method!!!
  #            if ($url !~ m{^/=/}) {
  #                die "Error in command $i: url does not start by \"/=/\"\n";
  #            }

            local %ENV;
            $ENV{REQUEST_URI}    = $url;
            $ENV{REQUEST_METHOD} = $http_meth;
            my $cgi = new_mocked_cgi( $url, $content );
            my $call_level = $openresty->call_level;
            $call_level++;
            my $account = $openresty->current_user;
            my $res
                = OpenResty::Dispatcher->process_request( $cgi, $call_level,
                $account );
            push @outputs, $res;

        } else {    # being a SQL method, $cmd->[0] is the fragments list
            my $pg_sql = join_frags_with_args( $cmd->[0], $args );

            if ( substr( $pg_sql, 0, 6 ) eq 'select' ) {
                my $res = $openresty->select( $pg_sql,
                    { use_hash => 1, read_only => 1 } );
                push @outputs, $res;
            } else {

                # XXX FIXME
                # we should use anonymous roles here in the future:
                my $retval = $openresty->do($pg_sql);
                push @outputs, { success => 1, rows_affected => $retval + 0 };
            }
        }
    }
    return \@outputs;
}

# Delete action with the given name, if the given action name is '~' then
# all existing actions for current user will be deleted by DELETE_action_list.
sub DELETE_action {
    my ( $self, $openresty, $bits ) = @_;
    my $name = $bits->[1];

# If the given action name is wildcard ('~'), then forward the request to DELETE_action_list
    if ( $name eq '~' ) {
        return $self->DELETE_action_list( $openresty, $bits );
    }

    # Delete parameters used by the action
    #die "HERE!";
    $openresty->do(
        [:sql|
            delete from _actions
            where name = $name cascade; |]
    );

    return { success => 1 };
}

# Create a named action (no overwrite permitted)
# This routine will do the following things:
#     1. Make sure there are no actions with the same name yet.
#     2. Compile the action definition with restyscript.
#     3. Collect variable names and types from the compiled result,
#     and check against the action parameter list.
#     4.
sub POST_action {
    my ( $self, $openresty, $bits ) = @_;

    my $body = $openresty->{_req_data};
    die "Invalid body content, must be a JSON object"
        unless ( ref($body) eq 'HASH' );
    die "Action definition must be given"
        unless ( exists( $body->{definition} ) );

    my $act_name = ( $bits->[1] eq '~' ) ? $body->{name} : $bits->[1];
    my $act_def  = $body->{definition};  # action definition, no default value
    my $act_desc = $body->{description}; # action description, default to ''
    my $act_params = $body->{parameters}
        || [];    # action parameter list, default to []

    # Make sure action name was given
    die "Action name should be specified in URL or body content."
        unless ($act_name);

    # Check if the action has been defined to prevent overwriting
    my $sql = [:sql|
        select name
        from _actions
        where name = $act_name |];
    my $act_list = $openresty->select( $sql, { use_hash => 1 } );
    die "Action \"$act_name\" already exists.\n"
        if (@$act_list);

    # Only array reference type allowed for parameter list
    die "Invalid \"parameters\" list: $act_params\n"
        unless ( ref($act_params) eq 'ARRAY' );

# Each action parameter is described by a hash containing the following keys:
#     name     - Param name, mandatory. No duplicate name allowed.
#     type     - Param type, mandatory. Must be one of 'literal', 'symbol' or 'keyword'
#     label     - Param label/description, optional. Default to '';
#     default - Param default value, optional. Default to null.
    my $params = {
        map {
            die "Missing parameter name.\n"
                unless ( defined( $_->{name} ) );
            die "Missing \"type\" for parameter \"$_->{name}\".\n"
                unless ( defined( $_->{type} ) );
            die "Invalid \"type\" for parameter \"$_->{name}\": "
                . $json->encode( $_->{type} ) . "\n"
                unless ( !ref( $_->{type} )
                && $_->{type} =~ /^(?:symbol|literal|keyword)$/i );

            $_->{name} => $_ } @$act_params
    };

    # Instance a restyscript object to compile action
    my $view = OpenResty::RestyScript->new( 'action', $act_def );
    my ( $frags, $stats ) = $view->compile;
    die 'Failed to invoke RestyScript'
        if ( !$frags && !$stats );

    # Check if too many commands are given:
    my $cmds = $frags;
    if ( @$cmds > $ACTION_CMD_COUNT_LIMIT ) {
        die
            "Too many commands in the action (should be no more than $ACTION_CMD_COUNT_LIMIT)\n";
    }

    # $vars is the vars actually used in the action definition
    my ( $vars, $canon_cmds )
        = $self->compile_frags( $openresty, $cmds );
    $self->process_params_with_vars( $openresty, $vars, $params );

    # Verify existences for models used in the action definition
    my @models = @{ $stats->{modelList} };
    $self->validate_model_names( $openresty, \@models );

    # Insert action definition into backend
    my $compiled = $OpenResty::JsonXs->encode([ $params, $canon_cmds ]);
    $sql = [:sql|
        insert into _actions (name, definition, description, compiled)
        values($act_name, $act_def, $act_desc, $compiled) |];
    my $rv = $openresty->do($sql);
    die "Failed to insert action into backend DB"
        unless ( defined($rv) );
    my $act_id = $openresty->last_insert_id('_actions');

    # Insert action parameters into backend
    $sql = '';
    for my $name ( keys(%$params) ) {
        my $param = $params->{$name};
        my $type = $param->{type};
        my $label = $param->{label};
        my $default = $param->{default_value};
        my $used = $param->{used} ? 'true' : 'false';
        $sql .= [:sql|
            insert into _action_params (name, type, label, default_value, used, action_id)
            values ($name, $type, $label, $default, $kw:used, $act_id) |];
    }
    $rv = $openresty->do($sql);
    #warn $rv;
    return { success => 1 };
}

# Verify the types for variables used in action definition against those in parameter list
sub process_params_with_vars {
    my ( $self, $openresty, $vars, $params ) = @_;

    for my $name ( keys(%$vars) ) {
        if (!exists $params->{$name}) {
            die "Parameter \"$name\" used in the action definition is not defined in the \"parameters\" list.\n"
        }
        if ($vars->{$name} ne 'unknown' and
                $vars->{$name} ne $params->{$name}{type}) {
            die "Invalid \"type\" for parameter \"$name\". (It's used as a $vars->{$name} in the action definition.)\n";
         }

        # TODO: perform type checks
        $params->{$name}{used} = 1;
    }
}

# Walking through the compiled action definition, collect variables and their inferenced types
sub compile_frags {
    my ( $self, $openresty, $cmds ) = @_;

    my %vars;
    my @canon_cmds;
    for my $cmd (@$cmds) {
        die "Invalid command: ", Dumper($cmd), "\n" unless ref $cmd;
        if ( @$cmd == 1 and ref $cmd->[0] ) {    # being a SQL command
            my $seq = $cmd->[0];

            # Check for variable uses:
            for my $frag (@$seq) {
                if ( ref $frag ) {                  # being a variable
                    my ( $var_name, $var_type ) = @$frag;

# Make sure inferenced variable type is consistent
# FIXME: 'unknown' type should be overwritten by concrete types (eg. 'symbol')
                    if ( exists $vars{$var_name}
                        && $vars{$var_name} ne $var_type )
                    {
                        die "Type inference conflict for variable \"$var_name\".";
                    }

                    # Collect variable and its type
                    $vars{$var_name} = $var_type;
                }
            }
            #### SQL: $cmd->[0]
      # We preserve a nested array ref here to distinguish SQL and HTTP method
            push @canon_cmds, $cmd;
        } else {    # being an HTTP command
            my ( $http_meth, $url, $content ) = @$cmd;
            if ( $http_meth ne 'POST' and $http_meth ne 'PUT' and $content ) {
                die "Content part not allowed for $http_meth\n";
            }
            my @bits = $http_meth;

            # Check for variable uses in $url:
            for my $fr (@$url) {
                if ( ref $fr ) {    # being a variable
                    my ( $vname, $vtype ) = @$fr;

     # Variable type inferenced in SQL action is preferred than in HTTP action
                    unless ( exists $vars{$vname} ) {
                        $vars{$vname} = $vtype;
                    }
                }
            }
            push @bits, $url;

            if ( $content && @$content ) {

                # Check for variable uses in $content:
                for my $frag (@$content) {
                    if ( ref $frag ) {    # being a variable
                        my ( $var_name, $var_type ) = @$frag;

     # Variable type inferenced in SQL action is preferred than in HTTP action
                        unless ( exists $vars{$var_name} ) {
                            $vars{$var_name} = $var_type;
                        }
                    }
                }

                push @bits, $content;
            }
            push @canon_cmds, \@bits;
        }
    }

    return ( \%vars, \@canon_cmds );
}

sub exec_RunView {
    my ($self, $openresty) = @_;

    my $sql = $openresty->{_req_data};
    ### Action sql: $sql
    if (length $sql > $VIEW_MAX_LEN) { # more than 10 KB
        die "SQL input too large (must be under 5 KB)\n";
    }

    _STRING($sql) or
        die "Restyscript source must be an non-empty literal string: ", $OpenResty::Dumper->($sql), "\n";
   #warn "SQL 1: $sql\n";

    my $view = OpenResty::RestyScript->new('view', $sql);
    my ($frags, $stats) = $view->compile;
    ### $frags
    ### $stats
    if (!$frags && !$stats) { die "Failed to invoke RunView\n" }

    # Check if variables are used:
    for my $frag (@$frags) {
        if (ref $frag) {
            die "Variables not allowed in the input to RunView: $frag->[0]\n";
        }
    }

    my @models = @{ $stats->{modelList} };
    $self->validate_model_names($openresty, \@models);
    my $pg_sql = $frags->[0];

    $openresty->select($pg_sql, {use_hash => 1, read_only => 1});
}

sub exec_RunAction {
    my ($self, $openresty) = @_;

    my $sql = $openresty->{_req_data};
    ### Action sql: $sql
    if (length $sql > $ACTION_MAX_LEN) { # more than 10 KB
        die "SQL input too large (must be under 5 KB)\n";
    }

    _STRING($sql) or
        die "Restyscript source must be an non-empty literal string: ", $OpenResty::Dumper->($sql), "\n";
   #warn "SQL 1: $sql\n";

    my $view = OpenResty::RestyScript->new('action', $sql);
    my ($frags, $stats) = $view->compile;
    ### $frags
    ### $stats
    if (!$frags && !$stats) { die "Failed to invoke RunAction\n" }

    # Check if too many commands are given:
    my $cmds = $frags;
    if (@$cmds > $ACTION_CMD_COUNT_LIMIT) {
        die "Too many commands in the action (should be no more than $ACTION_CMD_COUNT_LIMIT)\n";
    }

    my @final_cmds;
    for my $cmd (@$cmds) {
        die "Invalid command: ", Dumper($cmd), "\n" unless ref $cmd;
        if (@$cmd == 1 and ref $cmd->[0]) {   # being a SQL command
            my $cmd = $cmd->[0];
            # Check for variable uses:
            for my $frag (@$cmd) {
                if (ref $frag) {  # being a variable
                    die "Variable not allowed in the input to RunAction: $frag->[0]\n";
                }
            }
            #### SQL: $cmd->[0]
            push @final_cmds, $cmd->[0];
        } else { # being an HTTP command
            my ($http_meth, $url, $content) = @$cmd;
            if ($http_meth ne 'POST' and $http_meth ne 'PUT' and $content) {
                die "Content part not allowed for $http_meth\n";
            }
            my @bits = $http_meth;

            # Check for variable uses in $url:
            for my $frag (@$url) {
                if (ref $frag) { # being a variable
                    die "Variable not allowed in the input to RunAction: $frag->[0]\n";
                }
            }
            push @bits, $url->[0];

            # Check for variable uses in $url:
            for my $frag (@$url) {
                if (ref $frag) { # being a variable
                    die "Variable not allowed in the input to RunAction: $frag->[0]\n";
                }
            }

            push @bits, $content->[0] if $content && @$content;
            push @final_cmds, \@bits;
        }
    }

    my @models = @{ $stats->{modelList} };
    $self->validate_model_names($openresty, \@models);

    my @outputs;
    my $i = 0;
    for my $cmd (@final_cmds) {
        $i++;
        if (ref $cmd) { # being an HTTP method
            my ($http_meth, $url, $content) = @$cmd;
            if ($url !~ m{^/=/}) {
                die "Error in command $i: url does not start by \"/=/\"\n";
            }
            #die "HTTP commands not implemented yet.\n";
            local %ENV;
            $ENV{REQUEST_URI} = $url;
            $ENV{REQUEST_METHOD} = $http_meth;
            (my $query = $url) =~ s/(.*?\?)//g;
            $ENV{QUERY_STRING} = $query;
            my $cgi = new_mocked_cgi($url, $content);
            my $call_level = $openresty->call_level;
            $call_level++;
            my $account = $openresty->current_user;
            my $res = OpenResty::Dispatcher->process_request($cgi, $call_level, $account);
            push @outputs, $res;
        } else {
            my $pg_sql = $cmd;
            if (substr($pg_sql, 0, 6) eq 'select') {
                my $res = $openresty->select($pg_sql, {use_hash => 1, read_only => 1});
                push @outputs, $res;
            } else {
                # XXX FIXME
                # we should use anonymous roles here in the future:
                my $retval = $openresty->do($pg_sql);
                push @outputs, {success => 1,rows_affected => $retval+0};
            }
        }
    }
    return \@outputs;
}

sub validate_model_names {
    my ( $self, $openresty, $models ) = @_;
    for my $model (@$models) {
        _IDENT($model) or die "Bad model name: \"$model\"\n";
        if ( !$openresty->has_model($model) ) {
            die "Model \"$model\" not found.\n";
        }
    }
}

# Modify a existing action property (rise error when the dest action didn't exist)
sub PUT_action {
    my ( $self, $openresty, $bits ) = @_;
    my $act_name = $bits->[1];
    if ( $act_name eq '~' ) {
        die "Action name must be specified before executing.";
    }

    # Make sure the given action already existed
    my $sql = [:sql|
        select id, compiled
        from _actions
        where name = $act_name |];
    my $res = $openresty->select( $sql, { use_hash => 1 } );
    if ( !$res || @$res == 0 ) {
        die "Action \"$act_name\" not found.";
    }

    my $body = $openresty->{_req_data};
    die "Invalid PUT body content, must be a JSON object"
        unless ( ref($body) eq 'HASH' );

# TODO: PUT更改action的定义时需要注意：
# 1. 更改action的name时需要检测是否存在已经与目标name同名的action，若有则失败;
# 2. 更改action的description时可以直接更改，没有需要检测的地方;
# 3. 更改action的definition时需要检测其是否能通过编译、编译后片段所需的参数
# 是否已经存在、参数类型是否相符，当所需参数之前尚不存在或类型不同时则失败，
# 否则就更新definition和compiled字段，并根据变量使用情况对应更改参数的used字段;
# 4. 更改action的parameters时，需要检测新参数列表是否包含了原action definition所需
# 的变量，若没有完全包含则失败，否则就更新参数变量并根据使用情况修改变量的used
# 字段。
    die "Not completed yet.";
}

1;
__END__

=head1 NAME

OpenResty::Handler::Action - The action handler for OpenResty

=head1 SYNOPSIS

=head1 DESCRIPTION

This OpenResty handler class implements the Action API, i.e., the C</=/action/*> stuff.

=head1 METHODS

=head1 AUTHORS

chaoslawful (王晓哲) C<< <chaoslawful at gmail dot com> >>,
Agent Zhang (agentzh) C<< <agentzh@yahoo.cn> >>

=head1 SEE ALSO

L<OpenResty::Handler::Model>, L<OpenResty::Handler::Role>, L<OpenResty::Handler::View>, L<OpenResty::Handler::Feed>, L<OpenResty::Handler::Version>, L<OpenResty::Handler::Captcha>, L<OpenResty::Handler::Login>, L<OpenResty>.

