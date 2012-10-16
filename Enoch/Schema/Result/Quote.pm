use utf8;
package Enoch::Schema::Result::Quote;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Enoch::Schema::Result::Quote

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<DBIx::Class::InflateColumn::DateTime>

=back

=cut

__PACKAGE__->load_components("InflateColumn::DateTime");

=head1 TABLE: C<quote>

=cut

__PACKAGE__->table("quote");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  extra: {unsigned => 1}
  is_auto_increment: 1
  is_nullable: 0

=head2 channel

  data_type: 'varchar'
  default_value: (empty string)
  is_nullable: 0
  size: 64

=head2 quote

  data_type: 'text'
  is_nullable: 0

=head2 nick

  data_type: 'varchar'
  default_value: (empty string)
  is_nullable: 0
  size: 32

=head2 nick_id

  data_type: 'integer'
  default_value: 0
  extra: {unsigned => 1}
  is_nullable: 0

=head2 added

  data_type: 'datetime'
  datetime_undef_if_invalid: 1
  is_nullable: 1

=head2 rating

  data_type: 'float'
  default_value: 0
  extra: {unsigned => 1}
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type => "integer",
    extra => { unsigned => 1 },
    is_auto_increment => 1,
    is_nullable => 0,
  },
  "channel",
  { data_type => "varchar", default_value => "", is_nullable => 0, size => 64 },
  "quote",
  { data_type => "text", is_nullable => 0 },
  "nick",
  { data_type => "varchar", default_value => "", is_nullable => 0, size => 32 },
  "nick_id",
  {
    data_type => "integer",
    default_value => 0,
    extra => { unsigned => 1 },
    is_nullable => 0,
  },
  "added",
  {
    data_type => "datetime",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
  "rating",
  {
    data_type => "float",
    default_value => 0,
    extra => { unsigned => 1 },
    is_nullable => 0,
  },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");


# Created by DBIx::Class::Schema::Loader v0.07025 @ 2012-10-16 06:20:51
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:psGB0q3PKFfmwCbUzbUnQw


# You can replace this text with custom code or comments, and it will be preserved on regeneration

# A Quote has zero or one of the below.
__PACKAGE__->might_have(
    'rel_nick' => 'Enoch::Schema::Result::Nick',
    { 'foreign.id' => 'self.nick_id' }
);

# A Quote has zero or more of the below.
__PACKAGE__->has_many(
    'rel_ratings' => 'Enoch::Schema::Result::Rating',
    { 'foreign.quote_id' => 'self.id' }
);

1;
