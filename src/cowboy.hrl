-ifndef(COWBOY_HRL).


-ifdef(OTP_RELEASE).
%% >= OTP 21
-define(CATCH(Type, Reason, Stacktrace), Type:Reason:Stacktrace).
-define(STACK(Stacktrace), Stacktrace).
-else.
%% =< OTP 20
-define(CATCH(Type, Reason, Stacktrace), Type:Reason).
-define(STACK(Stacktrace), erlang:get_stacktrace()).
-endif.

-define(COWBOY_HRL, 'true').
-endif.

