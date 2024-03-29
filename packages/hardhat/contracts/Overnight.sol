// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.0/contracts/access/Ownable.sol";
import "./math.sol";

interface INTBt {
    function balanceOf(address) external returns (uint);
    function name() external returns (string memory);
    function symbol() external returns (string memory);
    function decimals() external returns (uint);
    function totalSupply() external returns (uint);
    function privilegedTransfer(address, address, uint) external returns (bool);
    function getTokenPrice() external returns (uint256);
}

interface IBRLt {
    function balanceOf(address) external returns (uint);
    function name() external returns (string memory);
    function symbol() external returns (string memory);
    function decimals() external returns (uint);
    function totalSupply() external returns (uint);
    function privilegedTransfer(address, address, uint) external returns (bool);
}

contract Overnight is Ownable, DSMath {
    struct LiquidityProvidedInfo {
        address provider;
        uint256 amount;
    }

    address public BRLtAddress;
    mapping(address => bool) public privilegedAccounts; // Serviços governamentais e bancos;
    mapping(address => uint256) liquidityProvidersScore; 

    struct liquidityRequest {
        string institution;
        address institutionAddress;
        uint256 totalAmount;
        uint256 raisedAmount;
        address collateralAsset;
        uint256 collateralAmount;
        uint256 requestDate;
        address[] liquidityProviderAddresses; // Array para armazenar os endereços dos provedores
        mapping(address => uint256) liquidityProviders; // Mapping de provedores de liquidez
        Status status;
    }

    enum Status {
        Open,
        Closed
    }

    liquidityRequest[] public liquidityRequests;

    constructor(address _BRLtAddress) {
        BRLtAddress = _BRLtAddress;
        privilegedAccounts[msg.sender] = true;
        privilegedAccounts[address(this)] = true;
    }

    modifier onlyPrivileged() {
        require(privilegedAccounts[msg.sender], "Acesso negado: conta nao privilegiada");
        _;
    }

    function addPrivilegedAccount(address account) public onlyOwner {
        privilegedAccounts[account] = true;
    }

    function removePrivilegedAccount(address account) public onlyOwner {
        privilegedAccounts[account] = false;
    }

    function createLiquidityRequest(string memory _institution, uint256 _totalAmount, address _collateralAsset) public onlyPrivileged returns(bool) {
        // Create a new instance of liquidityRequest directly in storage
        liquidityRequest storage newRequest = liquidityRequests.push();

        // Define the properties of the new liquidity request
        newRequest.institution = _institution;
        newRequest.institutionAddress = msg.sender;
        newRequest.totalAmount = _totalAmount;
        newRequest.raisedAmount = 0;
        newRequest.collateralAsset = _collateralAsset;
        newRequest.collateralAmount = (_totalAmount * 10 ** 18) / (INTBt(_collateralAsset).getTokenPrice());
        newRequest.requestDate = block.timestamp;
        newRequest.status = Status.Open;

        // Lock collateral assets on smartcontract
        privilegedTransferNTBt(_collateralAsset, msg.sender, address(this), newRequest.collateralAmount);

        return true;
    }

    function provideLiquidity(uint256 _liquidityRequestIndex, uint256 _provideAmount) public onlyPrivileged returns (bool) {
        //Check if the liquidity request exists
        require(_liquidityRequestIndex < liquidityRequests.length, "Request index out of bounds");

        //Checks whether the amount sent exceeds the liquidity request
        require(_provideAmount <= (liquidityRequests[_liquidityRequestIndex].totalAmount - liquidityRequests[_liquidityRequestIndex].raisedAmount), "This value exceeds the value to be raised");

        //Send money to the bank and register it in the system
        privilegedTransferReal(msg.sender, liquidityRequests[_liquidityRequestIndex].institutionAddress, _provideAmount);
        liquidityRequests[_liquidityRequestIndex].raisedAmount += _provideAmount;

        //Verify if the provider is already on the liquidity providers list and add him
        if (liquidityRequests[_liquidityRequestIndex].liquidityProviders[msg.sender] == 0) {
            liquidityRequests[_liquidityRequestIndex].liquidityProviderAddresses.push(msg.sender);
        }

        liquidityRequests[_liquidityRequestIndex].liquidityProviders[msg.sender] += _provideAmount;
        
        //Increase his Liquidity Score
        liquidityProvidersScore[msg.sender] += _provideAmount; 

        return true;
    }

    function payCreditors(uint256 _liquidityRequestIndex) public onlyPrivileged returns (bool) {
        require(_liquidityRequestIndex < liquidityRequests.length, "Request index out of bounds");
        liquidityRequest storage request = liquidityRequests[_liquidityRequestIndex];

        require(msg.sender == request.institutionAddress, "This request is not yours!");

        //Pay all the ones who provided liquidity with a daily interest rate (In Brazil, it is called Selic Over)
        for (uint i = 0; i < request.liquidityProviderAddresses.length; i++) {
            address provider = request.liquidityProviderAddresses[i];
            uint256 amount = request.liquidityProviders[provider];

            if (amount > 0) {
                uint256 realAmount = (amount * INTBt(request.collateralAsset).getTokenPrice())/(10**18);

                privilegedTransferReal(msg.sender, provider, realAmount);
                // Resetar o montante para evitar re-pagamentos
                request.liquidityProviders[provider] = 0;
            }
        }
        
        //Send the collateral back and close the request
        privilegedTransferNTBt(request.collateralAsset, address(this), request.institutionAddress, request.collateralAmount);
        request.status = Status.Closed;

        return true;
    }

    function defaultPayment(uint256 _liquidityRequestIndex) public onlyPrivileged returns (bool) {
        // Ensure the provided request index is within bounds
        require(_liquidityRequestIndex < liquidityRequests.length, "Request index out of bounds");
        liquidityRequest storage request = liquidityRequests[_liquidityRequestIndex];

        // Ensure that the request status is Open, allowing for default
        require(request.status == Status.Open, "Status closed");

        // Check if 24 hours have passed since the requestDate
        require(block.timestamp >= (request.requestDate + 86400), "Cannot default before 24 hours");

        uint256 amountProvided = request.liquidityProviders[msg.sender];
        require(amountProvided > 0, "No liquidity provided by sender");

        // Calculate the proportion of collateral to be returned based on the provided amount
        uint256 collateralToReturn = (amountProvided * 10 ** 18 / INTBt(request.collateralAsset).getTokenPrice());

        // Transfer the proportional collateral back to the sender
        privilegedTransferNTBt(request.collateralAsset, address(this), msg.sender, collateralToReturn);

        // Update the raisedAmount and collateralAmount in the request
        request.raisedAmount -= amountProvided;
        request.collateralAmount -= collateralToReturn;

        // Remove the liquidity contribution from the provider
        request.liquidityProviders[msg.sender] = 0;

        return true;
    }

    function privilegedTransferReal(address _from, address _to, uint256 _amount) public onlyPrivileged {
        IBRLt(BRLtAddress).privilegedTransfer(_from, _to, _amount);
    }

    function privilegedTransferNTBt(address _NTBtAddress, address _from, address _to, uint256 _amount) public onlyPrivileged {
        INTBt(_NTBtAddress).privilegedTransfer(_from, _to, _amount);
    }

}