package MineViewer;
use Dancer ':syntax';
use Dancer::Plugin::DBIC;
use Dancer::Plugin::ProxyPath;

# For caching results we do not expect to change
use Attribute::Memoize;

=head1 VERSION

Software release version: 0.01

Changes:

=over

=item * 0.01 - Initial release

Support for lists in a specific mine, and user comments 
on a per gene basis.

=back

=cut

our $VERSION = '0.1';

# InterMine client library code
use Webservice::InterMine 0.9700;
use Webservice::InterMine::Bio qw/GFF3 FASTA/;

# The connection to the main intermine webservice
my $service_args = setting('service_args');
my $service = Webservice::InterMine->get_service(@$service_args);

my $last_update = 0;
my $update_interval = setting('update_interval');
my $list_names = setting('gene_list_names');

use constant RESULT_OPTIONS => (as => 'jsonobjects'); 

before sub {
    if ($last_update < (time - $update_interval)) {
        $service->refresh_lists;
        $last_update = time;
    }
};

get '/' => sub {

    my @lists = map {$service->list($_)} @$list_names;

    return template index => {lists => [@lists]};
};

get '/templates' => sub {
    return template 'templates';
};

get '/lists' => sub {

    my @lists = map {$service->list($_)} @$list_names;

    return send_error("No gene lists found", 500) unless @lists;

    my $items = get_items_in_list($lists[0]);

    template lists => {
        class_keys => get_class_keys_for($lists[0]->type),
        items => $items, 
        lists => [@lists],
        gff_uri => proxy->uri_for('/list/' . $lists[0]->name . '.gff3'),
        fasta_uri => proxy->uri_for('/list/' . $lists[0]->name . '.fasta'),
    };
};

sub get_items_in_list :Memoize {
    my $list = shift;
    my $main_field = get_class_keys_for($list->type)->[0];
    my $query = $list->query;
    $query->set_sort_order($list->type . '.' . $main_field => 'asc');
    add_extra_views_to_query($list->type, $query);

    my $items = $list->results(as => 'hashrefs');
    return $items;
}

sub get_class_keys_for :Memoize {
    my $class = shift;
    my $class_keys = setting('class_keys');
    if (my $keys = $class_keys->{$class}) {
        debug("Returning " . to_dumper($keys));
        return $keys;
    } else {
        return $class_keys->{Default};
    }
}

get '/list/:list.gff3' => sub {
    content_type 'text/plain';
    header 'Content-Disposition' => 'attachment: filename=' . params->{list} . '.gff3';
    return get_list_gff3(params->{list});
};

sub get_list_gff3 :Memoize {
    my $list_name = shift;
    my $list = $service->list($list_name) or die "Cannot find list $list_name";
    my $query = $service->new_query(class => 'Gene', with => GFF3);
    $query->add_sequence_features(qw/Gene Gene.exons Gene.transcripts/);
    $query->add_constraint('Gene', 'IN', $list);
    return $query->get_gff3;
}

get '/list/:list.fasta' => sub {
    my $list = $service->list(params->{list});
    my $query = $service->new_query(class => 'Gene', with => FASTA);
    $query->add_constraint('Gene', 'IN', $list);
    content_type 'text/plain';
    header 'Content-Disposition' => 'attachment: filename=' . $list->name . '.fa';
    return $query->get_fasta;
};

get '/list/:list' => sub {

    my @lists = map {$service->list($_)} params->{list};

    return send_error("No gene lists found", 500) unless @lists;

    my $items = get_items_in_list($lists[0]);

    template lists => {
        class_keys => get_class_keys_for($lists[0]->type),
        items => $items, 
        lists => [@lists],
        gff_uri => proxy->uri_for('/list/' . $lists[0]->name . '.gff3'),
        fasta_uri => proxy->uri_for('/list/' . $lists[0]->name . '.fasta'),
    };

};

sub get_gff_url :Memoize{
    my $identifier = shift;
    my $gff_query = $service->new_query(class => 'Gene', with => GFF3);
    $gff_query->add_sequence_features(qw/Gene Gene.exons Gene.transcripts/);
    $gff_query->add_constraint('Gene', 'LOOKUP', $identifier);
    return $gff_query->get_gff3_uri;
}

sub get_fasta_url :Memoize{
    my $identifier = shift;
    my $fasta_query = $service->new_query(class => 'Gene', with => FASTA);
    $fasta_query->add_constraint('Gene', 'LOOKUP', $identifier);
    return $fasta_query->get_fasta_uri;
}

sub add_extra_views_to_query {
    my ($type, $query, $not_outer_joins) = (@_, []);
    my %dont_outer_join = map {$_ => 1} @$not_outer_joins;
    if (my $extra_views = setting('additional_summary_fields')->{$type}) {
        $query->add_views(@$extra_views);
        for (@$extra_views) {
            next if $dont_outer_join{$_};
            my @parts = split(/\./);
            my $join_path = shift @parts;
            do {
                $query->add_outer_join($join_path);
                $join_path .= '.' . shift @parts;
            } while (@parts);
        }
    }
}

sub get_item_query :Memoize {
    my $type = ucfirst(shift);
    my $identifier = shift;
    my @ids = split(/;/, $identifier);
    my $query = $service->new_query(class => $type);
    $query->add_views('*');
    if (@ids == 1) {
        add_extra_views_to_query($type, $query);
        $query->add_constraint($type, 'LOOKUP', $ids[0]);
    } else {
        my $class_keys = get_class_keys_for($type);
        add_extra_views_to_query($type, $query, $class_keys);
        for (my $i = 0; $i < @$class_keys; $i++) {
            my $path = $class_keys->[$i];
            my $value = $ids[$i];
            debug("Adding constraint: $path = $value");
            $query->add_constraint($path, '=', $value);
        }
    }
    return $query;
}

sub get_item_details :Memoize {
    my $query = get_item_query(@_);
    my ($item) = $query->results(RESULT_OPTIONS);
    return $item;
}

sub get_homologues :Memoize{
    my $identifier = shift;
    my $homologue_query = $service->new_query(class => 'Gene');
    $homologue_query->add_views(qw/primaryIdentifier symbol organism.name/);
    $homologue_query->add_constraint('organism.name', '!=', 'Homo sapiens');
    $homologue_query->add_constraint('homologues.homologue', 'LOOKUP', $identifier);
    my $homologues = $homologue_query->results(RESULT_OPTIONS);
    return $homologues;
}

get '/gene/:id' => sub {
    my $gene = get_item_details(gene => params->{id})
        or return template gene_error => params;

    my $display_name = $gene->{symbol} || $gene->{primaryIdentifier};
    my $identifier = $gene->{primaryIdentifier} || $gene->{symbol};
    my @comments = get_user_comments($identifier);

    # Generate Links for Sequence export
    my $gff_uri = get_gff_url($identifier);
    my $fasta_uri = get_fasta_url($identifier);

    # Get homologues in rat and mouse
    my $homologues = get_homologues($identifier);

    return template gene => {
        gene        => $gene, 
        displayname => $display_name, 
        comments    => [@comments],
        gff_uri     => $gff_uri, 
        fasta_uri   => $fasta_uri,
        homologues  => $homologues,
    };
};

get '/:type/:id' => sub {
    my $type = ucfirst(params->{'type'});
    my $query = get_item_query($type, params->{'id'});

    my ($item) = $query->results(as => 'hashrefs')
        or return template item_error => params;
    my ($obj) = $query->results(RESULT_OPTIONS)
        or return template item_error => params;

    my $keys = get_class_keys_for($type);
    my $identifier = join(';', map { defined($item->{"$type.$_"}) ? $item->{"$type.$_"} : ''} 
                            @$keys);

    my $displayname;
    for my $k (@$keys) {
        $displayname = $item->{"$type.$k"};
        last if $displayname;
    }

    my @comments = get_user_comments($identifier);

    debug("Rendering report for " . to_dumper($item));

    return template item => {
        item        => $item, 
        templates => get_subtemplate_for_type($type),
        obj         => $obj,
        identifier   => $identifier, 
        displayname => $displayname,
        comments    => [@comments],
    };
};

sub get_subtemplate_for_type :Memoize {
    my $type = lc(shift);
    if (-f "views/${type}_templates.tt") {
        return "${type}_templates.tt";
    }
    my $cd = $service->model->get_classdescriptor_by_name(ucfirst($type));
    for my $parent ($cd->parental_class_descriptors) {
        if (my $t = get_subtemplate_for_type($parent)) {
            return $t;
        }
    }
    return '';
}

sub get_user_comments {
    # TODO - change DB schema so it refers to items
    my $identifier = shift;
    my $gene_rs = schema('usercomments')->resultset('Gene')
                                        ->find_or_create({identifer => $identifier});
    my @comments = $gene_rs->comments->get_column('value')->all;
    return @comments;
}


post '/addcomment' => sub {
    my $id = params->{id};
    my $comment = params->{comment};
    my $gene_rs = schema('usercomments')->resultset('Gene')->find_or_create({identifer => $id});
    $gene_rs->add_to_comments({value => $comment});
    return to_json({id => $id, comment => $comment});
};

post '/removecomment' => sub {
    my $id = params->{geneid};
    my $comment = params->{commenttext};
    my $gene_rs = schema('usercomments')->resultset('Gene')->find_or_create({identifer => $id});
    $gene_rs->delete_related('comments', {value => $comment});
    return to_json({id => $id, comment => $comment});
};

true;
