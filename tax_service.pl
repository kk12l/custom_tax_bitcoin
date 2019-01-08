#!/usr/bin/env perl
use Mojolicious::Lite -signatures;
use POSIX qw(strftime);
use Bitcoin::RPC::Client;

my $btc = Bitcoin::RPC::Client->new(
   user     => "testuser",
   password => "123456",
   host     => "127.0.0.1:18443",
);

my $main_btc_address = "mkzKLnQY4essouXZb219pA7CPs11CxBwVA"; # Наш биткоин адрес

sub get_list_unspent {
  my @list = @{$btc->listunspent(6, 99999999, [$main_btc_address])};
  @list = sort {$a->{amount} <=> $b->{amount}} @list;
  return \@list;
}

get '/' => sub ($c) {
  my $address = $c->param('address');
  my $income_amount = $c->param('amount');
  my $income_fee = $c->param('fee');
  my $recommended_fee = app->ua->get(
                                      "https://bitcoinfees.earn.com/api/v1/fees/recommended"
                                    )->result->json("/fastestFee");
  app->log->info($recommended_fee);
  my $max_tx_size = int($income_fee * 100_000_000 / $recommended_fee);
  app->log->info($max_tx_size);
  my $max_quantity_btc_inputs = int(($max_tx_size - 10 - 2 * 34) / 180);
  die "Недостаточно комиссии" unless $max_quantity_btc_inputs;
  my @list_unspent = @{&get_list_unspent}; # Все UTXO отсортированные по возрастанию суммы аутпута
  my @tx_unspent = (); # UTXO для транзакции
  $max_quantity_btc_inputs = scalar(@list_unspent) if scalar(@list_unspent) < $max_quantity_btc_inputs;
  app->log->info($max_quantity_btc_inputs);
  my $sum = 0;
  # Берутся самые маленькие аутпуты с глобальной целью не пролететь на комиссиях
  for (0..$max_quantity_btc_inputs - 1) {
    push @tx_unspent, $list_unspent[$_];
    $sum += $list_unspent[$_]->{amount};
  };
  # Если набрать достаточную сумму не вышло, то из списка на формирование транзакции убирается самый большой аутпут
  # и добавляется самый большой аутпут изо всех UTXO. И так пока список на формирование транзакции не заполнится
  # аутпутами с максимальной суммой.
  if ($sum < $income_amount + $income_fee) {
    die "Недостаточно средств" if $max_quantity_btc_inputs == scalar(@list_unspent);
    app->log->info("Вторая попытка.");
    app->log->info($#list_unspent);
    for (my $i = $#list_unspent; $i >= ($#list_unspent - $max_quantity_btc_inputs); $i--) {
      app->log->info("index: $i");
      my $a = pop @tx_unspent;
      $sum -= $a->{amount};
      $sum += $list_unspent[$i]->{amount};
      unshift @tx_unspent, $list_unspent[$i];
      last if $sum >= $income_amount + $income_fee;
    };
  }
  die "Недостаточно средств" if $sum < $income_amount + $income_fee;
  for (@tx_unspent) {
    delete $_->{address};
    delete $_->{amount};
    delete $_->{confirmations};
    delete $_->{safe};
    delete $_->{scriptPubKey};
    delete $_->{solvable};
    delete $_->{spendable};
  };
  #app->log->info(app->dumper(\@tx_unspent));
  my %output = ($address => $income_amount, $main_btc_address => $sum - $income_amount - $income_fee);
  my $tx = $btc->createrawtransaction([\@tx_unspent, \%output]);
  app->log->info(app->dumper($tx));
  $tx = $btc->signrawtransaction ($tx)->{hex};
  #$btc->sendrawtransaction($tx);
  $c->render(text => "Комиссия за байт по факту: " . $income_fee / (length($tx) / 2) * 100_000_000 . " Рекомендуемая    комиссия за байт: " . $recommended_fee);
};

app->start;
