%%%-------------------------------------------------------------------
%%% @copyright (C) 2010-2013, 2600Hz
%%% @doc
%%% Utility module for V3 Kazoo Migration
%%% @end
%%% @contributors
%%%   Ben Wann
%%%-------------------------------------------------------------------
-module(cdr_v3_migrate_lib).

%% API
-export([get_n_month_date_list/2
         ,get_n_month_date_list/3
         ,get_last_n_months/3
	 ,generate_test_accounts/3
         ,get_test_account_details/1
	 ,delete_test_accounts/2
	]).

-include("cdr.hrl").

%%%===================================================================
%%% API
%%%===================================================================
-spec get_n_month_date_list(wh_datetime(), pos_integer()) -> wh_proplist().
-spec get_n_month_date_list(wh_year(), wh_month(), pos_integer()) -> wh_proplist().
get_n_month_date_list({{Year, Month, _}, _}, NumMonths) ->
    get_n_month_date_list(Year, Month, NumMonths).

get_n_month_date_list(Year, Month, NumMonths) ->
    DateRange = lists:reverse(get_last_n_months(Year, Month, NumMonths)),
    lists:foldl(fun get_n_month_date_list_fold/2, [], DateRange).

-spec get_n_month_date_list_fold({pos_integer(), pos_integer()}, list()) -> any().
get_n_month_date_list_fold({Year,Month}, Acc) ->
    [{Year,Month,Day}
     || Day <- lists:seq(calendar:last_day_of_the_month(Year,Month), 1, -1)
    ] ++ Acc.

-spec get_test_account_details(pos_integer()) -> api_binaries().
get_test_account_details(NumAccounts) ->
    [{<<"migratetest", (wh_util:to_binary(X))/binary>>
          , <<"migratetest",(wh_util:to_binary(X))/binary,".realm.com">>
          , <<"testuser", (wh_util:to_binary(X))/binary, "-user">>
          , <<"password">>
     } || X <- lists:seq(1, NumAccounts)].

-spec generate_test_accounts(pos_integer(), pos_integer(), pos_integer()) -> 'ok'.
generate_test_accounts(NumAccounts, NumMonths, NumCdrs) ->
    CdrJObjFixture = wh_json:load_fixture_from_file('cdr', "fixtures/cdr.json"),
    lists:foreach(fun(AccountDetail) -> 
                          generate_test_account(AccountDetail, NumMonths, NumCdrs, CdrJObjFixture) 
                  end, get_test_account_details(NumAccounts)).

-spec generate_test_account({ne_binary(),ne_binary(), ne_binary(), ne_binary()}
                            ,pos_integer(), pos_integer()
                            ,wh_json:object()
                           ) -> 'ok' | {'error', any()}.
generate_test_account({AccountName, AccountRealm, User, Pass}, NumMonths, NumCdrs, CdrJObjFixture) ->
    crossbar_maintenance:create_account(AccountName, AccountRealm, User, Pass),
    wh_cache:flush(),
    case get_account_by_realm(AccountRealm) of
	{'ok', AccountDb} ->
	    DateRange = get_n_month_date_list(calendar:universal_time(), NumMonths),
	    lists:foreach(fun(Date) -> 
                                  generate_test_account_cdrs(AccountDb, CdrJObjFixture, Date, NumCdrs) 
                          end, DateRange);
	{'multiples', AccountDbs} ->
	    lager:debug("Found multiple DBS for Account Name: ~p", [AccountDbs]),
            {'error', 'multiple_account_dbs'};
	{'error', Reason} ->
	    lager:debug("Failed to find account: ~p [~s]", [Reason, AccountName]),
            {'error', Reason}
    end.

-spec get_account_by_realm(ne_binary()) -> 
                                  {'ok', account_db()} | {'multiples', any()} | {'error', any()}.
get_account_by_realm(AccountRealm) ->
    case couch_mgr:get_results(?WH_ACCOUNTS_DB, <<"accounts/listing_by_realm">>, [{'key', AccountRealm}]) of
        {'ok', [JObj]} ->
            AccountDb = wh_json:get_value([<<"value">>, <<"account_db">>], JObj),
            _AccountId = wh_util:format_account_id(AccountDb, 'raw'),
            {'ok', AccountDb};
        {'ok', []} ->
            {'error', 'not_found'};
        {'ok', [_|_]=JObjs} ->
            AccountDbs = [wh_json:get_value([<<"value">>, <<"account_db">>], JObj) || JObj <- JObjs],
            {'multiples', AccountDbs};
        _E ->
            lager:debug("error while fetching accounts by realm: ~p", [_E]),
            {'error', 'not_found'}
    end.

-spec generate_test_account_cdrs(ne_binary(), wh_json:object(), wh_date(), pos_integer()) -> 'ok'.
generate_test_account_cdrs(_, _, _, 0) -> 'ok';
generate_test_account_cdrs(AccountDb, CdrJObjFixture, Date, NumCdrs) ->
    DateTime = {Date, {random:uniform(23), random:uniform(59), random:uniform(59)}},
    lager:debug("CDR DateTime: ~p", [DateTime]),
    CreatedAt = calendar:datetime_to_gregorian_seconds(DateTime),
    Props = [{<<"call_id">>, <<(couch_mgr:get_uuid())/binary>>}
             ,{<<"timestamp">>, CreatedAt}
             ,{<<"pvt_created">>, CreatedAt}
             ,{<<"pvt_modified">>, CreatedAt}
            ],
    Doc = wh_json:set_values(Props, CdrJObjFixture),
    case couch_mgr:save_doc(AccountDb, Doc) of
        {'error',_}=_E -> lager:debug("CDR Save Failed: ~p", [_E]);
        {'ok', _} -> 'ok'
    end,
    generate_test_account_cdrs(AccountDb, CdrJObjFixture, Date, NumCdrs - 1).
    
-spec delete_test_accounts(pos_integer(), pos_integer()) -> 'ok'.
delete_test_accounts(NumAccounts, NumMonths) ->
    lists:foreach(fun(AccountDetails) -> 
                          delete_test_account(AccountDetails, NumMonths) 
                  end, get_test_account_details(NumAccounts)),
    'ok'.

-spec delete_test_account({ne_binary(), ne_binary(), ne_binary(), ne_binary()}
                          ,pos_integer()) -> 'ok' | {'error', any()}.
delete_test_account({_AccountName, AccountRealm, _User, _Pass}, NumMonths) ->		     
    case whapps_util:get_account_by_realm(AccountRealm) of
        {'ok', AccountDb} -> 
            {{CurrentYear, CurrentMonth, _}, _} = calendar:universal_time(),
            Months = get_last_n_months(CurrentYear, CurrentMonth, NumMonths),
            AccountId = wh_util:format_account_id(AccountDb, 'raw'),
            [delete_account_database(AccountId, {Year, Month}) 
             || {Year, Month} <- Months],
            couch_mgr:del_doc(<<"accounts">>, AccountId),
            couch_mgr:db_delete(AccountDb),
            'ok';
        {'multiples', AccountDbs} ->
            lager:debug("Found multiple DBS for Account Name: ~p", [AccountDbs]),
            {'error', 'not_unique'};
        {'error', Reason} ->
            lager:debug("Failed to find account: ~p [~s]", [Reason, _AccountName]),
            {'error', Reason}
    end.

-spec delete_account_database(account_id(), {wh_year(), wh_month()}) -> 
                                     'ok' | {'error', any()}.
delete_account_database(AccountId, {Year, Month}) ->
    AccountMODb = wh_util:format_account_id(AccountId, Year, Month),
    couch_mgr:db_delete(AccountMODb).

-spec get_last_n_months(pos_integer(), pos_integer(), pos_integer()) -> wh_proplist().
get_last_n_months(CurrentYear, CurrentMonth, NumMonths) when CurrentMonth =< 12, CurrentMonth > 0 ->
    get_last_n_months(CurrentYear, CurrentMonth, NumMonths, []).
    
%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
get_last_n_months(_, _, 0, Acc) ->
    lists:reverse(Acc);
get_last_n_months(CurrentYear, 1, NumMonths, Acc) ->
    get_last_n_months(CurrentYear - 1, 12, NumMonths - 1, [{CurrentYear, 1} | Acc]);
get_last_n_months(CurrentYear, Month, NumMonths, Acc) ->
    get_last_n_months(CurrentYear, Month -1, NumMonths - 1, [{CurrentYear, Month} | Acc]).
   