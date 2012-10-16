use utf8;
package Enoch::Schema::Result::Nick;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Enoch::Schema::Result::Nick

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<nick>

=cut

__PACKAGE__->table("nick");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  extra: {unsigned => 1}
  is_auto_increment: 1
  is_nullable: 0

=head2 nick

  data_type: 'varchar'
  default_value: (empty string)
  is_nullable: 0
  size: 32

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type => "integer",
    extra => { unsigned => 1 },
    is_auto_increment => 1,
    is_nullable => 0,
  },
  "nick",
  { data_type => "varchar", default_value => "", is_nullable => 0, size => 32 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 UNIQUE CONSTRAINTS

=head2 C<nick>

=over 4

=item * L</nick>

=back

=cut

__PACKAGE__->add_unique_constraint("nick", ["nick"]);


# Created by DBIx::Class::Schema::Loader v0.07025 @ 2012-10-16 03:13:31
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:B3fOv0LkyGKzcvN17aXuPg


# You can replace this text with custom code or comments, and it will be preserved on regeneration

# A Nick has zero or more of the below.
__PACKAGE__->has_many(
    'rel_quotes' => 'Enoch::Schema::Result::Quote',
    { 'foreign.nick_id' => 'self.id' }
);

__PACKAGE__->has_many(
    'rel_ratings' => 'Enoch::Schema::Result::Rating',
    { 'foreign.nick_id' => 'self.id' }
);

1;
