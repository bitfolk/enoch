use utf8;
package Enoch::Schema::Result::Rating;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Enoch::Schema::Result::Rating

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

=head1 TABLE: C<rating>

=cut

__PACKAGE__->table("rating");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  extra: {unsigned => 1}
  is_auto_increment: 1
  is_nullable: 0

=head2 nick_id

  data_type: 'integer'
  default_value: 0
  extra: {unsigned => 1}
  is_nullable: 0

=head2 quote_id

  data_type: 'integer'
  default_value: 0
  extra: {unsigned => 1}
  is_nullable: 0

=head2 rating

  data_type: 'smallint'
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
  "nick_id",
  {
    data_type => "integer",
    default_value => 0,
    extra => { unsigned => 1 },
    is_nullable => 0,
  },
  "quote_id",
  {
    data_type => "integer",
    default_value => 0,
    extra => { unsigned => 1 },
    is_nullable => 0,
  },
  "rating",
  {
    data_type => "smallint",
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

=head1 UNIQUE CONSTRAINTS

=head2 C<nick_quote_id>

=over 4

=item * L</nick_id>

=item * L</quote_id>

=back

=cut

__PACKAGE__->add_unique_constraint("nick_quote_id", ["nick_id", "quote_id"]);


# Created by DBIx::Class::Schema::Loader v0.07025 @ 2012-10-16 06:20:51
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:p+1lHz7UWgfS4y8sa4pbEw


# You can replace this text with custom code or comments, and it will be preserved on regeneration

# A rating always has one of the below.
__PACKAGE__->belongs_to(
    'rel_nick' => 'Enoch::Schema::Result::Nick',
    { 'foreign.id' => 'self.nick_id' }
);

__PACKAGE__->belongs_to(
    'rel_quote' => 'Enoch::Schema::Result::Quote',
    { 'foreign.id' => 'self.quote_id' }
);

1;
