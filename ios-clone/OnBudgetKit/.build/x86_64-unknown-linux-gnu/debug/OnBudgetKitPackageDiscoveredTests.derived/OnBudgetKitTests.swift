import XCTest
@testable import OnBudgetKitTests

fileprivate extension APIDecodingTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__APIDecodingTests = [
        ("testAuthSessionDecodesGoTrueShape", testAuthSessionDecodesGoTrueShape),
        ("testGmailPollResultWithPerConnectionError", testGmailPollResultWithPerConnectionError),
        ("testMemberListRowDisplayNameFallbacks", testMemberListRowDisplayNameFallbacks),
        ("testPlaidItemAndEmailConnectionDecode", testPlaidItemAndEmailConnectionDecode),
        ("testPlaidSyncResultDecodes", testPlaidSyncResultDecodes),
        ("testRPCJsonbReturnsDecode", testRPCJsonbReturnsDecode),
        ("testTransactionDecodesFullRow", testTransactionDecodesFullRow),
        ("testTransactionTrashAndPendingRefundFlags", testTransactionTrashAndPendingRefundFlags),
        ("testUnknownKindDecodesWithoutFailing", testUnknownKindDecodesWithoutFailing),
        ("testWeekCloseResultDecodes", testWeekCloseResultDecodes),
        ("testWeekResultDecodesFlat", testWeekResultDecodesFlat),
        ("testWeekResultToleratesWrappedResult", testWeekResultToleratesWrappedResult)
    ]
}

fileprivate extension APIErrorMappingTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__APIErrorMappingTests = [
        ("test401FromRPCSurfacesAsSessionExpired", asyncTest(test401FromRPCSurfacesAsSessionExpired)),
        ("testAuthInvalidGrantMapsToGenericSignInMessage", testAuthInvalidGrantMapsToGenericSignInMessage),
        ("testEdgeFunction401SurfacesAsSessionExpired", asyncTest(testEdgeFunction401SurfacesAsSessionExpired)),
        ("testEdgeFunctionErrorBodyMapsByMessage", testEdgeFunctionErrorBodyMapsByMessage),
        ("testGmailOAuthStart409KeepsStatus", asyncTest(testGmailOAuthStart409KeepsStatus)),
        ("testLoadStateContract", testLoadStateContract),
        ("testPlaidSync502ParsesPartialFailure", asyncTest(testPlaidSync502ParsesPartialFailure)),
        ("testPostgrest401BodyMapsToSessionExpired", testPostgrest401BodyMapsToSessionExpired),
        ("testPostgrestErrorBodyMapsByMessage", testPostgrestErrorBodyMapsByMessage),
        ("testRPCErrorSurfacesThroughCall", asyncTest(testRPCErrorSurfacesThroughCall)),
        ("testServerRefusalsPreserveTextVerbatim", testServerRefusalsPreserveTextVerbatim),
        ("testSessionExpiredSignals", testSessionExpiredSignals),
        ("testURLErrorMapping", testURLErrorMapping)
    ]
}

fileprivate extension APISelectShapeTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__APISelectShapeTests = [
        ("testActivePlaidItemDecodesFromSelectedColumns", testActivePlaidItemDecodesFromSelectedColumns),
        ("testCharityIncomeDecodesFromSelectedColumns", testCharityIncomeDecodesFromSelectedColumns),
        ("testCharityIncomeHistoryDecodesFromSelectedColumns", testCharityIncomeHistoryDecodesFromSelectedColumns),
        ("testCharitySettingsDecodesFromSelectedColumns", testCharitySettingsDecodesFromSelectedColumns),
        ("testFundLedgerRowDecodesFromSelectedColumns", testFundLedgerRowDecodesFromSelectedColumns),
        ("testFundTopupDecodesFromSelectedColumns", testFundTopupDecodesFromSelectedColumns),
        ("testPlaidAccountDecodesFromSelectedColumns", testPlaidAccountDecodesFromSelectedColumns),
        ("testPlaidItemDecodesFromSelectedColumns", testPlaidItemDecodesFromSelectedColumns),
        ("testSurplusReleaseDecodesFromSelectedColumns", testSurplusReleaseDecodesFromSelectedColumns)
    ]
}

fileprivate extension APISummaryTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__APISummaryTests = [
        ("testCharitySummaryMirrorsLiveJS", testCharitySummaryMirrorsLiveJS),
        ("testFundRequestApprovedCents", testFundRequestApprovedCents),
        ("testFundSummaryMirrorsLiveJS", testFundSummaryMirrorsLiveJS),
        ("testReleasedFallsBackToSurplusWhenZero", testReleasedFallsBackToSurplusWhenZero)
    ]
}

fileprivate extension AuthRequestTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__AuthRequestTests = [
        ("testSignInRequest", testSignInRequest),
        ("testSignUpCarriesFullNameMetadata", testSignUpCarriesFullNameMetadata),
        ("testUpdateUserUsesPUTWithBearer", testUpdateUserUsesPUTWithBearer)
    ]
}

fileprivate extension EdgeFunctionRequestTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__EdgeFunctionRequestTests = [
        ("testAllFunctionNames", testAllFunctionNames),
        ("testComputeWeekSendsOnlyHouseholdId", testComputeWeekSendsOnlyHouseholdId),
        ("testPlaidExchangeBody", testPlaidExchangeBody)
    ]
}

fileprivate extension FundsReadDecodingTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__FundsReadDecodingTests = [
        ("testCharityIncomeDecodesFromFixedColumns", testCharityIncomeDecodesFromFixedColumns),
        ("testCharitySettingsDecodesFromFixedColumns", testCharitySettingsDecodesFromFixedColumns),
        ("testFundLedgerDecodesFromFixedColumns", testFundLedgerDecodesFromFixedColumns),
        ("testFundTopupsDecodeFromFixedColumns", testFundTopupsDecodeFromFixedColumns),
        ("testHeldRefundsDecodeFromFixedColumns", testHeldRefundsDecodeFromFixedColumns),
        ("testMerchantAliasesDecodeFromFixedColumns", testMerchantAliasesDecodeFromFixedColumns),
        ("testPendingDuplicateCandidatesDecodeFromFixedColumns", testPendingDuplicateCandidatesDecodeFromFixedColumns),
        ("testRefundLinkDismissalsDecodeFromFixedColumns", testRefundLinkDismissalsDecodeFromFixedColumns),
        ("testResolvedDuplicateCandidatesDecodeFromFixedColumns", testResolvedDuplicateCandidatesDecodeFromFixedColumns),
        ("testRestorationEntriesDecodeFromFixedColumns", testRestorationEntriesDecodeFromFixedColumns),
        ("testSurplusReleasesDecodeFromFixedColumns", testSurplusReleasesDecodeFromFixedColumns)
    ]
}

fileprivate extension OnBudgetKitTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__OnBudgetKitTests = [
        ("testDesignTokenHexValues", testDesignTokenHexValues),
        ("testSupabaseConfigurationPresent", testSupabaseConfigurationPresent),
        ("testTitleCaseKeepsMinorWordsLowercase", testTitleCaseKeepsMinorWordsLowercase),
        ("testToastStyleIsBrandBlue", testToastStyleIsBrandBlue)
    ]
}

fileprivate extension PostgrestQueryTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__PostgrestQueryTests = [
        ("testFetchAllPagesWalks1000RowPages", asyncTest(testFetchAllPagesWalks1000RowPages)),
        ("testFetchPageProbeReturnsHasMore", asyncTest(testFetchPageProbeReturnsHasMore)),
        ("testInFilterAndIlikeRendering", testInFilterAndIlikeRendering),
        ("testTransactionsPageQueryMatchesLiveJS", testTransactionsPageQueryMatchesLiveJS)
    ]
}

fileprivate extension RPCRequestTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__RPCRequestTests = [
        ("testAddFundMoneyParams", testAddFundMoneyParams),
        ("testApproveAndAllocateSendsNullOverrideWhenAbsent", testApproveAndAllocateSendsNullOverrideWhenAbsent),
        ("testCharityGiftParams", testCharityGiftParams),
        ("testCreateHouseholdPassesPName", asyncTest(testCreateHouseholdPassesPName)),
        ("testExcludeRestoreDeleteUseExactParamNames", testExcludeRestoreDeleteUseExactParamNames),
        ("testJoinHouseholdNullBodyDecodesToNil", asyncTest(testJoinHouseholdNullBodyDecodesToNil)),
        ("testLinkRefundUsesPParamsAndReturnsPurchaseId", asyncTest(testLinkRefundUsesPParamsAndReturnsPurchaseId)),
        ("testReclassifySendsExactNameAndParams", testReclassifySendsExactNameAndParams),
        ("testResolveDuplicateCandidateParams", testResolveDuplicateCandidateParams),
        ("testWeeklyOverrideLoopWritesOneRowPerWeek", asyncTest(testWeeklyOverrideLoopWritesOneRowPerWeek))
    ]
}

fileprivate extension SHA256Tests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__SHA256Tests = [
        ("testCSVDedupeRowHashFormat", testCSVDedupeRowHashFormat),
        ("testCharityGiftHashIncludesNonce", testCharityGiftHashIncludesNonce),
        ("testFIPSVectors", testFIPSVectors),
        ("testManualDedupeHashFormat", testManualDedupeHashFormat)
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __OnBudgetKitTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(APIDecodingTests.__allTests__APIDecodingTests),
        testCase(APIErrorMappingTests.__allTests__APIErrorMappingTests),
        testCase(APISelectShapeTests.__allTests__APISelectShapeTests),
        testCase(APISummaryTests.__allTests__APISummaryTests),
        testCase(AuthRequestTests.__allTests__AuthRequestTests),
        testCase(EdgeFunctionRequestTests.__allTests__EdgeFunctionRequestTests),
        testCase(FundsReadDecodingTests.__allTests__FundsReadDecodingTests),
        testCase(OnBudgetKitTests.__allTests__OnBudgetKitTests),
        testCase(PostgrestQueryTests.__allTests__PostgrestQueryTests),
        testCase(RPCRequestTests.__allTests__RPCRequestTests),
        testCase(SHA256Tests.__allTests__SHA256Tests)
    ]
}