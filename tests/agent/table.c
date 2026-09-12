#include "../../net-snmp/agent/helpers/table.c"

static int probe_called;

static int
probe_handler(netsnmp_mib_handler *handler,
              netsnmp_handler_registration *reginfo,
              netsnmp_agent_request_info *reqinfo,
              netsnmp_request_info *requests)
{
    netsnmp_request_info *request;
    probe_called++;
    for (request = requests; request; request = request->next) {
        if (!request->processed && !netsnmp_extract_table_info(request))
            return 99;
    }
    return SNMP_ERR_NOERROR;
}

int
main(void)
{
    oid root[] = { 1, 3, 6, 1, 4, 1, 8072, 999 };
    oid invalid_oid[] = { 0 };
    oid valid_oid[] = { 1, 3, 6, 1, 4, 1, 8072, 999, 1, 1, 7 };
    netsnmp_variable_list index, invalid_vb, valid_vb;
    netsnmp_table_registration_info table_info;
    netsnmp_mib_handler table_handler, child_handler;
    netsnmp_handler_registration registration;
    netsnmp_agent_request_info request_info;
    netsnmp_request_info invalid_request, valid_request;
    int status;

    memset(&index, 0, sizeof(index));
    memset(&invalid_vb, 0, sizeof(invalid_vb));
    memset(&valid_vb, 0, sizeof(valid_vb));
    memset(&table_info, 0, sizeof(table_info));
    memset(&table_handler, 0, sizeof(table_handler));
    memset(&child_handler, 0, sizeof(child_handler));
    memset(&registration, 0, sizeof(registration));
    memset(&request_info, 0, sizeof(request_info));
    memset(&invalid_request, 0, sizeof(invalid_request));
    memset(&valid_request, 0, sizeof(valid_request));

    index.type = ASN_INTEGER;
    table_info.indexes = &index;
    table_info.number_indexes = 1;
    table_info.min_column = 1;
    table_info.max_column = 1;

    child_handler.handler_name = "regression-probe";
    child_handler.access_method = probe_handler;
    table_handler.handler_name = TABLE_HANDLER_NAME;
    table_handler.myvoid = &table_info;
    table_handler.next = &child_handler;
    child_handler.prev = &table_handler;

    registration.rootoid = root;
    registration.rootoid_len = OID_LENGTH(root);
    request_info.mode = MODE_GETBULK;

    invalid_vb.name = invalid_oid;
    invalid_vb.name_length = OID_LENGTH(invalid_oid);
    invalid_vb.type = ASN_NULL;
    valid_vb.name = valid_oid;
    valid_vb.name_length = OID_LENGTH(valid_oid);
    valid_vb.type = ASN_NULL;
    invalid_request.requestvb = &invalid_vb;
    invalid_request.next = &valid_request;
    valid_request.requestvb = &valid_vb;

    status = table_helper_handler(&table_handler, &registration,
                                  &request_info, &invalid_request);

#ifdef EXPECT_FIXED
    if (status != SNMP_ERR_NOERROR || probe_called != 1 ||
        invalid_request.processed != 1)
        return 1;
#else
    if (status != 99 || probe_called != 1 || invalid_request.processed != 0)
        return 2;
#endif

    netsnmp_free_request_data_sets(&invalid_request);
    netsnmp_free_request_data_sets(&valid_request);
#ifdef EXPECT_FIXED
    puts("PASS: out-of-range GetBulk varbind is skipped by the next table handler");
#else
    puts("PASS negative control: out-of-range GetBulk varbind reaches the next table handler unprocessed");
#endif
    return 0;
}
