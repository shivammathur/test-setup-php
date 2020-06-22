<?php
/*
 * BandwidthLib
 *
 * This file was automatically generated by APIMATIC v2.0 ( https://apimatic.io ).
 */

namespace BandwidthLib\TwoFactorAuth\Models;

/**
 * @todo Write general description for this model
 */
class TwoFactorCodeRequestSchema implements \JsonSerializable
{
    /**
     * The phone number to send the 2fa code to.
     * @required
     * @var string $to public property
     */
    public $to;

    /**
     * The application phone number, the sender of the 2fa code.
     * @required
     * @var string $from public property
     */
    public $from;

    /**
     * The application unique ID, obtained from Bandwidth.
     * @required
     * @var string $applicationId public property
     */
    public $applicationId;

    /**
     * An optional field to denote what scope or action the 2fa code is addressing.  If not supplied,
     * defaults to "2FA".
     * @var string|null $scope public property
     */
    public $scope;

    /**
     * The message format of the 2fa code.  There are three values that the system will replace "{CODE}",
     * "{NAME}", "{SCOPE}".  The "{SCOPE}" and "{NAME} value template are optional, while "{CODE}" must be
     * supplied.  As the name would suggest, code will be replace with the actual 2fa code.  Name is
     * replaced with the application name, configured during provisioning of 2fa.  The scope value is the
     * same value sent during the call and partitioned by the server.
     * @required
     * @var string $message public property
     */
    public $message;

    /**
     * The number of digits for your 2fa code.  The valid number ranges from 2 to 8, inclusively.
     * @required
     * @var double $digits public property
     */
    public $digits;

    /**
     * Constructor to set initial or default values of member properties
     */
    public function __construct()
    {
        if (6 == func_num_args()) {
            $this->to            = func_get_arg(0);
            $this->from          = func_get_arg(1);
            $this->applicationId = func_get_arg(2);
            $this->scope         = func_get_arg(3);
            $this->message       = func_get_arg(4);
            $this->digits        = func_get_arg(5);
        }
    }

    /**
     * Encode this object to JSON
     */
    public function jsonSerialize()
    {
        $json = array();
        $json['to']            = $this->to;
        $json['from']          = $this->from;
        $json['applicationId'] = $this->applicationId;
        $json['scope']         = $this->scope;
        $json['message']       = $this->message;
        $json['digits']        = $this->digits;

        return array_filter($json);
    }
}
