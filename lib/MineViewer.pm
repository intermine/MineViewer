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

get '/lists' => sub {

    my @lists = map {$service->list($_)} @$list_names;

    return send_error("No gene lists found", 500) unless @lists;

    my $genes = get_genes_in_list($lists[0]);

    template lists => {
        genes => $genes, 
        lists => [@lists],
        gff_uri => proxy->uri_for('/list/' . $lists[0]->name . '.gff3'),
        fasta_uri => proxy->uri_for('/list/' . $lists[0]->name . '.fasta'),
    };
};

sub get_genes_in_list :Memoize {
    my $list = shift;
    $list->query->set_sort_order('Gene.symbol' => 'asc');
    my $genes = $list->results(RESULT_OPTIONS);
    return $genes;
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

    my $genes = get_genes_in_list($lists[0]);

    template lists => {
        genes => $genes, 
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

sub get_gene_details :Memoize{
    my $identifier = shift;
    my $query = $service->new_query(class => 'Gene');
    $query->add_views('symbol', 'primaryIdentifier', 'summary', 'organism.name', 
        'chromosome.primaryIdentifier',
        'chromosomeLocation.start', 'chromosomeLocation.end');
    $query->add_outer_join('chromosome');
    $query->add_outer_join('chromosomeLocation');
    $query->add_constraint('Gene', 'LOOKUP', $identifier);
    my ($gene) = $query->results(RESULT_OPTIONS);
    return $gene;
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

    my $gene = get_gene_details(params->{id})
        or return template gene_error => {id => params->{id}};

    my $display_name = $gene->{symbol} || $gene->{primaryIdentifier};
    my $identifier = $gene->{primaryIdentifier} || $gene->{symbol};

    my $gene_rs = schema('usercomments')->resultset('Gene')
                                        ->find_or_create({identifer => $identifier});
    my @comments = $gene_rs->comments->get_column('value')->all;

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

post '/addcomment' => sub {
    my $id = params->{id};
    my $comment = params->{comment};
    my $gene_rs = schema('usercomments')->resultset('Gene')->find_or_create({identifer => $id});
    $gene_rs->add_to_comments({value => $comment});
    $gene_rs->update;
    return to_json({id => $id, comment => $comment});
};

post '/removecomment' => sub {
    my $id = params->{geneid};
    my $comment = params->{commenttext};
    my $gene_rs = schema('usercomments')->resultset('Gene')->find_or_create({identifer => $id});
    my $comments = $gene_rs->search_related('comments', {value => $comment});
    $comments->delete();
    return to_json({id => $id, comment => $comment});
};

true;
