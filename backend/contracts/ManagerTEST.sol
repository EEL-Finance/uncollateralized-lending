// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "@sismo-core/sismo-connect-solidity/contracts/SismoConnectLib.sol";
import "./CometHelper.sol";

contract ManagerContract is
    SismoConnect // inherits from Sismo Connect library
{
    bytes16 public constant GITCOIN_PASSPORT_HOLDERS =
        0x1cde61966decb8600dfd0749bd371f12;
    bytes16 public constant ROCIFI_CREDIT_HOLDERS =
        0xb3ac412738ed399acab21fbda9add42c;
    event ResponseVerified(SismoConnectVerifiedResult result);
    event vaultIdReceived(uint256 value1);

    bytes16 private _appId = 0xf4977993e52606cfd67b7a1cde717069;
    // allow impersonation
    bool private _isImpersonationMode = true; // remove later
    mapping(address => uint256) public userToVaultId; // Ethereum address to Vault ID
    mapping(address => uint16) public creditScores; //store user's credit score

    constructor()
        SismoConnect(
            buildConfig({
                appId: _appId,
                isImpersonationMode: _isImpersonationMode
            })
        ) // <--- Sismo Connect constructor
    {}

    // frontend requests, backend verifies, but we need to recreate the request made in the fontend to verify the proof
    function verifySismoConnectResponse(bytes memory response) public {
        // Recreate the request made in the fontend to verify the proof
        // We will verify the Sismo Connect Response containing the ZK Proofs against it
        AuthRequest[] memory auths = new AuthRequest[](1);
        auths[0] = buildAuth({authType: AuthType.VAULT});

        ClaimRequest[] memory claims = new ClaimRequest[](2);
        claims[0] = buildClaim({
            // claim Gitcoin Passport Holders Data Group membership
            groupId: GITCOIN_PASSPORT_HOLDERS,
            value: 20,
            claimType: ClaimType.GTE
        });
        claims[1] = buildClaim({
            // claim Rocifi Credit Score Data Group membership
            groupId: ROCIFI_CREDIT_HOLDERS,
            // the value can be selected by the user to gain more tokens
            isSelectableByUser: true,
            // this proof of group membership optional
            isOptional: true
        });

        // verify the response regarding our original request
        SismoConnectVerifiedResult memory result = verify({
            responseBytes: response,
            auths: auths,
            claims: claims,
            signature: buildSignature({message: abi.encode(msg.sender)})
        });

        // if the proofs and signed message are valid, we take the userId from the verified result
        // in this case the userId is the vaultId (since we used AuthType.VAULT in the auth request),
        // it is the anonymous identifier of a user's vault for a specific app
        // --> vaultId = hash(userVaultSecret, appId)
        uint256 vaultId = SismoConnectHelper.getUserId(result, AuthType.VAULT);
        userToVaultId[msg.sender] = vaultId;
        emit vaultIdReceived(vaultId);
        // each vaultId can claim points relatively to their aggregated reputation
        uint256 pointAmount = getPointAmount(result);
        creditScores[msg.sender] = uint16(pointAmount);

        emit ResponseVerified(result);
    }

    function getPointAmount(
        SismoConnectVerifiedResult memory result
    ) private pure returns (uint256) {
        uint256 pointAmount = 0;
        uint256 POINT_BASE_VALUE = 1 * 10 ** 18; // 1 point
        // we iterate over the verified claims in the result
        for (uint i = 0; i < result.claims.length; i++) {
            bytes16 groupId = result.claims[i].groupId;
            uint256 value = result.claims[i].value;
            if (groupId == ROCIFI_CREDIT_HOLDERS) {
                // for ROCIFI_CREDIT_HOLDERS, the value is your credit score
                if (value > 8) {
                    pointAmount += 0;
                } else if (value == 7 || value == 8) {
                    pointAmount += 2;
                } else if (value == 6) {
                    pointAmount += 4;
                } else if (value == 5) {
                    pointAmount += 5;
                } else if (value == 4) {
                    pointAmount += 6;
                } else if (value == 3) {
                    pointAmount += 8;
                } else if (value == 2) {
                    pointAmount += 9;
                } else if (value == 1) {
                    pointAmount += 10;
                }
            } else {
                // for all other groups, the value is 1 point
                pointAmount += POINT_BASE_VALUE;
            }
        }
        return pointAmount;
    }

    function estimateLoan(
        address user
    ) public view returns (uint16, uint256, uint256, uint256) {
        uint16 score = creditScores(user);
        uint256 interestRate;
        uint256 loanAmount;
        uint256 collateralAmount;

        // Loan conditions based on credit score
        if (score < 2) revert("Not eligible for loans.");
        else if (score < 4) {
            interestRate = 50;
            loanAmount = 5 ether;
            collateralAmount = (loanAmount * 150) / 100;
        } else if (score < 5) {
            interestRate = 20;
            loanAmount = 5 ether;
            collateralAmount = (loanAmount * 120) / 100;
        } else {
            interestRate = 50 - 5 * score;
            loanAmount = 5 ether + (score >= 9 ? 5 ether : 0);
            collateralAmount =
                (loanAmount * (10 >= score ? 10 - score : 0)) /
                10;
        }
        return (score, interestRate, loanAmount, collateralAmount);
    }
}

contract LoanFactory is ManagerContract {
    // This contract must be funded aka it is used as treasury
    address public _collateralAsset =
        0x3587b2F7E0E2D6166d6C14230e7Fe160252B0ba4; // Goerli COMP
    address public _borrowAsset = 0x07865c6E87B9F70255377e024ace6630C1Eaa37F; // Goerli USDC
    mapping(address => CometHelper) public specificComets; //store user's comet contract address

    ERC20 public token = ERC20(_collateralAsset);
    address public Owner;
    address public _ManagerContract;

    event LiquidationEvent();

    constructor(address manager) {
        _ManagerContract = manager;
        Owner = msg.sender;
    }

    modifier onlyBorrower() {
        require(address(specificComets[msg.sender]) != address(0)); // "User does not have an active loan."
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == Owner); // "Caller doesn't have enough permissions."
        _;
    }

    function sendEtherToTreasury() public payable {
        // Need to make it proper collateral assets
        uint amount = 2;
        require(msg.value >= amount, "Insufficient Ether sent");

        // Perform any additional checks or logic if needed

        // Transfer the Ether to the treasury address (address of this contract)
        token.transfer(address(this), amount);

        // You can now perform any additional logic or emit events related to the Ether transfer.
    }

    function getLoan() public {
        ManagerContract manager = ManagerContract(_ManagerContract);
        require(
            userToVaultId[msg.sender] != 0,
            "User is not verified with Sismo"
        );
        require(address(specificComets[msg.sender]) == address(0)); //"User already has an active loan."
        (, , uint256 borrowable, uint256 collateral) = manager.estimateLoan(
            msg.sender
        ); // We estimate loan and also check that user has digital identity and meets the requirements
        require( // We get some payment from user just to ensure that they have access to some funds. We might have to return it also but right we'll treat only as a 'payment' to get the contract
            token.transferFrom(msg.sender, address(this), collateral)
            // "Transfer failed. Ensure you've approved this contract."
        );
        uint collateralAmount = borrowable * 2; // For now, we just supply twice as much collateral to make everything easier but ideally we need a proper way which calls Compound for minimal borrowable amount etc.
        require(address(this).balance >= collateralAmount); // "Not enough funds in the factory contract."
        CometHelper cometUser = new CometHelper(address(this));
        specificComets[msg.sender] = cometUser;
        require(token.transfer(address(cometUser), collateralAmount)); // "Token transfer to user's treasury failed."
        cometUser.supply(_collateralAsset, collateralAmount); // We supply collateral
        cometUser.withdrawToUser(_borrowAsset, borrowable, msg.sender); // We get the borrowed amount to user's treasury
    }

    /*
        Determines how much the user must repay in order to get back on a healthy score;
        We can do a loop off-chain to actually check it. Probably will have to run node.js server to constanly kick this function but it also means that it will have to rn thorugh every single one of the 
        loans which is not gas efficient at all, as we are on testnet right now, we don't really care. And I'm sure this will do the trick for the hackathon but for future we will for sure need something 
        more efficient.
        These 3 functions are going to be monitored off-chain (node.js server).
    */
    function checkRepay(address user) public view returns (int, int) {
        CometHelper cometUser = specificComets[user];
        (int health, int repay) = cometUser.needToRepay(_collateralAsset);
        return (health, repay);
    }

    function checkLiquitable(address user) public view returns (bool) {
        CometHelper cometUser = specificComets[user];
        return cometUser.liquitable();
    }

    function checkPayment(address user) public view returns (uint, uint) {
        CometHelper cometUser = specificComets[user];
        return (block.timestamp, cometUser.paymentDue());
    }

    /*
        These events are going to be called off-chain after the above functions are monitored
    */
    function liquidateEvent(address user) public onlyOwner {
        // Downgrade credit score (a lot)
        CometHelper cometUser = specificComets[user];
        cometUser.liquidate(_collateralAsset, address(this));
    }

    function overduePaymentEvent(address user, uint day) public onlyOwner {
        CometHelper cometUser = specificComets[user];
        // "Overdue can only be charged with 1 day intervals."
        require((block.timestamp - cometUser.overdueCharged()) / 86400 >= 1); // Checking to ensure that at least 1 day has passed since we last charged borrower with overdue payment
        cometUser.setIsOverdue(true);
        cometUser.setOverdueCharged(block.timestamp);
        // Downgrade credit score (depending on how many days)
    }

    function repayDueDay(address user) public onlyOwner {
        CometHelper cometUser = specificComets[user];
        cometUser.setRepayDue(block.timestamp + 86400); // Reset the repay date
    }

    /*
        Repay back the borrowed amount
    */
    function repayInterestRate() public payable onlyBorrower {
        (, int amount) = checkRepay(msg.sender);
        require(
            token.transferFrom(msg.sender, address(this), uint(amount)) // "Transfer failed. Ensure you've approved this contract."
        );

        token.transferFrom(
            address(this),
            address(specificComets[msg.sender]),
            uint(amount) / 2
        );

        specificComets[msg.sender].supply(_borrowAsset, uint(amount) / 2);
        CometHelper cometUser = specificComets[msg.sender];
        cometUser.setIsOverdue(false);
    }

    function repayFull() public payable onlyBorrower {
        CometHelper cometUser = specificComets[msg.sender];
        int owedAmount = cometUser.owed();
        require(
            token.transferFrom(msg.sender, address(this), uint(owedAmount)) // "Transfer failed. Ensure you've approved this contract."
            // With full commission
        );

        token.transferFrom(
            address(this),
            address(cometUser),
            uint(owedAmount / 2)
        );
        cometUser.repayFullBorrow(_borrowAsset, _collateralAsset);
        delete cometUser;
    }

    function totalOwed() public view onlyBorrower returns (int) {
        return specificComets[msg.sender].owed() * 2; // With 50% commission
    }
}
