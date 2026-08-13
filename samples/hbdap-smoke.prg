#include "hbdap.ch"

PROCEDURE Main()

   LOCAL cJson := hb_dapJsonEncode( { "status" => "ok", "component" => "hbdap" } )

   IF '"status":"ok"' $ cJson .AND. '"component":"hbdap"' $ cJson
      OutStd( "HBDAP_SMOKE_OK" + hb_eol() )
      RETURN
   ENDIF

   ErrorLevel( 1 )

RETURN
